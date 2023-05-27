#!/usr/bin/env bash
# exit on error
set -o errexit

## Setup
# bundle install
# npm ci or npm install

# Compile assets
npm run build

# Delete old site completely
ssh -t websites "sudo rm -rf /var/www/tobiasmikula.com/htdocs/*"

# Upload the site to dentalwissen VPS
rsync -avzhP --rsync-path="sudo rsync" ./dist/ tobi@websites:/var/www/tobiasmikula.com/htdocs

# Set permissions
ssh -t websites "sudo chown -R www-data:www-data /var/www/tobiasmikula.com/htdocs"
