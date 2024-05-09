# DigitalOcean to Hybrid DigitalOcean + AWS deployment

In Q1 2024 we began moving from a DigitalOcean based deployment to a hybrid of DigitalOcean + AWS-based.

This occurred initially as a cost saving measure, but also as part of experiment with modern AWS Lambdas. In a modern world Lambdas can run a whole Docker image, and `aws-lambda-web-adapter` exists as glue to allow us to run a Django app inside a lambda without having to worry about translating between HTTP and Lambdaese.

Experiments using Mapa as a basis show comprable performance. For example, DigitalOcean can return a large Mapa features payload in 1.5 - 1.6s, whereas Lambdas return in 1.7 - 1.9s.

Our new deployment pattern is:

1. We've migrated out PostgreSQL database completely from DigitalOcean to AWS. (This saves costs and is necessary to be able to allow-list the Lambdas to be able to talk to it.)
2. Over time we'll convert all of our apps over to this deployment pattern. Mapa was just the first.
3. Certain apps with low usage, like Mapa, always run on Lambdas.
4. Other apps, with spikey usage, like DemSausage, run on Lambdas when usage is low and then transition back to DigitalOcean for high usage events.

# TODO

0. Add active monitoring and alarms for the database being down and/or non-responsive (incl. alarms for important metrics being too high for too long)
1. Migrate Mapa PROD across so we can finally destroy that droplet
2. Plan for migrating DemSausage across to allow it to run on Lambdas
  2.1 Refer here for the initial set of changes we made to Mapa: https://github.com/keithamoss/mapa/commit/c9f01f398babfaacf5b57c1c9ca44910775cb3ca
  2.2 What does switching over between Lambdas and Droplets look like? How much effort is involved and how much can we automate?
  2.3 How are Redis and Memcached for caching going to work when we are (a) running Lambdas + S3 Static Site (b) running Droplets
3. Explore cost saving options for the PostgreSQL EC2 (e.g. paid on a 1 or 3yr term to get a reduced cost)
4. Migrate the Projects Database setup from Click Ops to CDK (See `db/TODO.md`)

# Analysis and backstory

So, we're looking at a complete lift and shift to AWS.

Why? Well, DigitalOcean functions are (a) too limited w/ the 48MB package size, (b) only support zipped code packages, not containers, and (c) don't have any native adapters for receiving requests and translating them into web requests for Django (though, we could probably hack together a little translator easily enough).

AWS Lambdas natively support running off a container, and have their own domain names now (so no need for API Gateway), however we then run into the issue of how to allow the lambdas to talk to the database in DigitalOcean.

Our starting point is that we'd need to allow-list them by IP. To do that, we need a stable IP that we can allow-list. We could try and use a wide AWS IP range, but that's opening us up for trouble.

There are two ways to provide stable IP addresses to lambdas. The proper way is to use a NAT gateway ($42.48/month) and the hacky way is to associate elastic IPs with the two Network interfaces (EC2 - because that's how lambdas run under-the-hood) established by the lambdas ($3.6/month).

We managed to sort of get the Lambda ENI w/ Elastic IPs option working once, and then it never did - but we think it wasn't a database connection issue and more of a Python/Django-land issue. It's hard to debug because the actual Python/Django errors weren't being surfaced from the lambda - the tasks just timed out.

With this pathway a bust, we next considered a full migration from DigitalOcean to AWS.

We looked at RDS and Aurora and the costs were all far in excess of what we're paying on DO (understandably, given they're not just bare metal database services).

So we're left with a lift-and-shift where we run tiny EC2s as equivalents of DO's droplets.

That's where the difference in the charging models for AWS (pay for everything as-you-go) vs DigitalOcean (pay once off and get a guaranteed server w/ storage and up to 1000GiB/month of free data transfer) comes in. With AWS, we're charged for the server, attaching EBS storage, outbound data transfer to the internet (if you're not using CloudFront).

A single EC2 for the database server could be $8.27/month - $11/month depending on data transfer out.

CloudFront would be around $4/month - maybe, that's without working out the international costs for non-Australia/NZ regions.

Route 53 would cost $0.9/month

We'd probably want to take advantage of WAF and Shield so we can replicate some of the specific caching rules we have in CloudFlare (e.g. Trove on the Go?).

Oh, did I mention we'd probably have to leave CloudFlare for CloudFront+WAF+Shield - or pay for elastic IPs for everything - to make this work.

They'd probably cost a bit.

And then we'd probably need elastic IPs ($3.6/month \* 3 = $10.8/month) (to point at in Route 35) or a load balancer ($18.4/month)

And all of this is just considering moving db-A, DemSausage (x2), and Mapa across, not EALGIS.

So, in short - it makes costs more unpredictable (bad during a Federal election) and would be a massive migration of 5+ years of infrastructure.

Decision #1: Monitor how DigitalOcean's platform evolves and use their Functions service when that becomes viable.

Decision #2: Get the best of both worlds for now by moving the PostgreSQL database to AWS. This means we can run Lambdas most of the time and switch to DigitalOcean Droplets as needed for each service.