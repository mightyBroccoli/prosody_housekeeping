# Prosody housekeeping

This script is designed to fight of unnecessary database space and junk.

## Needed
- Prosody Server
- Prosody Community Modules listed in the main config file or in the path
- shell access

## How to install
Edit the script to fit your timeframes and paths. Add the cerdentials of your prosodys database users to the file and enable mod_mam clearing.
Start daily with cron or place script as .sh file in the "cron.daily" anacron directory.

## Work Flow
- Filter registered but never logged in accounts
- Filter formerly used but now unused accounts
- if enabled delete expired mod_mam entries
- delete all filtered users
