# TODO

# Health Checks

Add some simple health checks for our production services.

Maybe https://www.icinga.com?

# CloudFlare Cache Tuning

CloudFlare caching...would be caching index.html all of the time without a bypass, no?

Result: So, it looks like CF isn't caching index.html at all? But it IS working with the .js/.css files (CF: HIT and Expires in 30 minutes show correctly in headers).

What we want to do -

-   Bypass cache for: API and index.html files
-   Use CF cache for all other files (if they need to change the filenames will change)
-   Have Nginx set special caching headers on index.html (Cache-Control: public, max-age=7200, s-maxage=3600) and set a PageRule for "Origin Cache Control" for index.html
    -   https://support.cloudflare.com/hc/en-us/articles/115003206852-Origin-Cache-Control
-   Set the CF Browser Cache back to 4 hours
-   When we deploy the stack ... do nothing? OR use the CF API to solely invalidate the index.html cache so we can avoid having to use a PageRule to define that?
-   See Result above...seems a bit overly complex if what we have is doing the job.
