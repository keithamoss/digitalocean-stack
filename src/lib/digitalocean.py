import os
import datetime
from time import sleep
import digitalocean
import requests
import subprocess
import shutil
from lib.s3 import upload_to_s3
from lib.logset import myLog
logger = myLog()


class Deploy:
    def __init__(self, digitalocean_token, github_personal_access_token, snapshot_name, floating_ip):
        self.digitalocean_token = digitalocean_token
        self.snapshot_name = snapshot_name
        self.floating_ip = floating_ip
        self.github_personal_access_token = github_personal_access_token
        self.manager = digitalocean.Manager(token=self.digitalocean_token)

        # 1. Determine if an existing Droplet is running.
        # If so, we'll need to cleanup and shut it down once the new stack is up.
        self.old_droplet = self.getRunningDroplet()

        # 2. Create a new droplet using our stack's standard config
        self.new_droplet = self.createDroplet()

        # 3. Poll Digital Ocean until the droplet has started up successfully
        self.waitForDropletToBootUp(self.new_droplet)

        # 4. Poll until our Dockerised stack inside the droplet has started up succesfully
        self.waitForDockerStackToStartUp(self.new_droplet)

        # 5. Switch our Floating IP to the new droplet
        self.switchFloatingIP(self.new_droplet)

        # 6. Cleanup and destroy our old droplet
        # self.old_droplet = [d for d in self.manager.get_all_droplets() if d.name.startswith("scremsong-stack-foobar")][0]
        if self.old_droplet is not None:
            self.shutdownOldDroplet(self.old_droplet)

    def ___createDropletName(self):
        r = requests.get("https://api.github.com/repos/keithamoss/digitalocean-stack/git/refs/heads/master", headers={
            "Authorization": "token {token}".format(token=self.github_personal_access_token)
        })
        print("status_code", r.status_code)
        print("body", r.text)
        return "stack-a-{hash}".format(hash=r.json()["object"]["sha"][:7])

    def __waitForDropletActionToComplete(self, droplet):
        while True:
            actions = droplet.get_actions()
            action = actions[0]
            action.load()
            if action.status == "completed":
                break
            sleep(1)

    def __getSnapshotId(self):
        snapshot_image = [i for i in self.manager.get_images(type="snapshot") if i.name == self.snapshot_name]

        if len(snapshot_image) == 1:
            return snapshot_image[0].id
        raise Exception("Unable to find a snapshot named {snapshot_name}.".format(snapshot_name=self.snapshot_name))

    def __buildCloudConfig(self):
        with open("src/cloud-config.yaml") as f:
            cloudConfig = f.read()
            with open("secrets/droplet-deploy.env") as f:
                cloudConfig = cloudConfig.replace("{DROPLET_DEPLOY_ENV}", f.read().replace("\n", "\n      "))
            with open("secrets/scremsong-web.env") as f:
                cloudConfig = cloudConfig.replace("{SCREMSONG_WEB_ENV}", f.read().replace("\n", "\n      "))
            with open("secrets/scremsong-db.env") as f:
                cloudConfig = cloudConfig.replace("{SCREMSONG_DB_ENV}", f.read().replace("\n", "\n      "))
            with open("secrets/pgbackups3.env") as f:
                cloudConfig = cloudConfig.replace("{PGBACKUPS3_ENV}", f.read().replace("\n", "\n      "))
        return cloudConfig

    def getRunningDroplet(self):
        droplets = [d for d in self.manager.get_all_droplets() if d.name.startswith("stack-a-")]

        if len(droplets) == 1:
            return droplets[0]
        elif len(droplets) > 1:
            logger.error("Oh dear. We've got {num} droplets, why didn't the old ones die?.".format(num=len(droplets)))
        elif len(droplets) == 0:
            logger.info("No droplet exists. That's OK - we'll just create the new one.")

    def createDroplet(self):
        name = self.___createDropletName()
        droplet = digitalocean.Droplet(token=self.digitalocean_token,
                                       name=name,
                                       region='sgp1',  # Singapore 1
                                       # image='docker-16-04',  # Ubuntu 14.04 x64
                                       image=self.__getSnapshotId(),
                                       size='s-1vcpu-1gb',  # 512MB
                                       ssh_keys=self.manager.get_all_sshkeys(),  # Automatic conversion
                                       tags=["scremsong"],
                                       backups=False,
                                       private_networking=True,
                                       user_data=self.__buildCloudConfig(),
                                       monitoring=True)
        # digitalocean.baseapi.DataReadError: error processing droplet creation, please try again
        droplet.create()
        logger.info("Droplet {name} created successfully.".format(name=name))
        return droplet

    def waitForDropletToBootUp(self, droplet):
        logger.info("Waiting for droplet to start")
        self.__waitForDropletActionToComplete(droplet)
        logger.info("Droplet started")

    def waitForDockerStackToStartUp(self, droplet):
        logger.info("Waiting for Docker stack to start")

        droplet.load()
        public_v4 = [i for i in droplet.networks["v4"] if i["type"] == "public"][0]
        url = "https://" + public_v4["ip_address"]
        logger.info("New stack is at {url}".format(url=url))

        attempts = 0
        while True:
            try:
                logger.info("Pinging...")
                response = requests.get(url, timeout=5, verify=False)
                logger.info(response.status_code)
                logger.info(response.text)

                if response.status_code == 200:
                    break
            except requests.exceptions.ConnectionError as e:
                logger.info("ConnectionError")

            attempts += 1
            sleep(5)
        logger.info("Docker stack is up! (attempts = {attempts})".format(attempts=attempts))

    def switchFloatingIP(self, droplet):
        f = digitalocean.FloatingIP(token=self.digitalocean_token, ip=self.floating_ip).assign(droplet_id=droplet.id)

        logger.info("Waiting for Floating IP to switch")
        self.__waitForDropletActionToComplete(droplet)
        logger.info("Floating IP switched to new droplet")

    def shutdownOldDroplet(self, droplet):
        # Wait a bit to allow any current requests om the old droplet to finish up
        logger.info("Waiting for any requests on the old droplet to finish up")
        sleep(5)

        # Exfiltrate log files from the old droplet
        logger.info("Grab logs out of the old droplet")
        os.makedirs("./logs/digitalocean/", exist_ok=True)
        public_v4 = [i for i in droplet.networks["v4"] if i["type"] == "public"][0]
        subprocess.check_output(["ssh-add", "./secrets/deploy_key"])
        subprocess.check_output(["scp", "-i ./secrets/deploy_key", "-o StrictHostKeyChecking=no", "-rp", "root@{ip}:/apps/digitalocean-stack/logs/".format(ip=public_v4["ip_address"]), "./logs/"])
        subprocess.check_output(["scp", "-i ./secrets/deploy_key", "-o StrictHostKeyChecking=no", "-rp", "root@{ip}:/var/log/cloud-init.log".format(ip=public_v4["ip_address"]), "./logs/digitalocean/cloud-init.log"])
        subprocess.check_output(["scp", "-i ./secrets/deploy_key", "-o StrictHostKeyChecking=no", "-rp", "root@{ip}:/var/log/cloud-init-output.log".format(ip=public_v4["ip_address"]), "./logs/digitalocean/cloud-init-output.log"])

        # Zip all logs
        logs_path = "./logs/"
        output_filename = "stack-a-{datetime}".format(datetime=datetime.datetime.now().strftime("%Y-%m-%dT%H-%M-%S"))
        shutil.make_archive(output_filename, "zip", logs_path)

        logger.info("Archive the logs in S3")
        s3_key = "scremsong/{}.zip".format(output_filename)
        if upload_to_s3("{}.zip".format(output_filename), s3_key) == False:
            raise Exception("Failed uploading {file} to S3.".format(file))
        else:
            logger.info("{} uploaded to S3".format(output_filename))

        # And finally, destroy the old droplet
        droplet.destroy()

        logger.info("Waiting for {droplet} to die".format(droplet=droplet.name))
        self.__waitForDropletActionToComplete(droplet)
        logger.info("It's an ex-Droplet")
        logger.info("All done!")
