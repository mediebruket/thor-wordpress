# Thor-Wordpress

A set of thor tasks for maintaining and deploying WordPress Applications

## Todo

* Use SSHKit for all ssh-commands.
* Remove all defaults
* Change naming convention to dev/stage/prod
* wp cli-wrapper. Ex.: thor wp:cli:update_option —name=home_url —value=http://example.com -e=prod
* Add debug related stuff to generated local-config.php

## Installation

## Usage

## Database Migrations

### Single site

`thor wp:db:sync [--from=production --to=development]`

### Multisite

`thor wp:db:sync [--from=production --to=development]`

In addition, the following updates are required (subfolder installation):

|                             | From          | To                  |
|-----------------------------|---------------|---------------------|
| wp_site/domain              | mysite.com    | sites               |
| wp_site/path                | /             | /mysite/            |
| wp_blogs/domain (main site) | mysite.com    | sites               |
| wp_blogs/path (main site)   | /             | /mysite/            |
| wp_blogs/domain (subsites)  | mysite.com    | sites               |
| wp_blogs/path (subsites)    | /             | /mysite/subsite/    |

wp-config.php:

`define('DOMAIN_CURRENT_SITE', 'mysite.com');`
to
`define('DOMAIN_CURRENT_SITE', 'sites');`

`define('PATH_CURRENT_SITE', '/');`
to
`define('PATH_CURRENT_SITE', '/mysite/');`