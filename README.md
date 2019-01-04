# digitalocean-stack

# Encrypting Secrets

Per Travis-CI's documentation on [encrypting multiple files containing secrets](https://docs.travis-ci.com/user/encrypting-files#Encrypting-multiple-files).

```
tar cvf secrets.tar secrets/
travis encrypt-file --force secrets.tar
```

# DigitalOcean Monitoring

...
