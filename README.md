[![Codacy Badge](https://api.codacy.com/project/badge/Grade/a44ab3c7c76d46cd93e135be9d4e1d12)](https://www.codacy.com/app/nico.wellpott/prosody_housekeeping?utm_source=github.com&amp;utm_medium=referral&amp;utm_content=mightyBroccoli/prosody_housekeeping&amp;utm_campaign=Badge_Grade)

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

## Ignore List
Feature to ignore defined user accounts by placing the full JID in the ignore file one per line. There is no need to take care of whitespaces or emtpy lines. The Skript will automatically prepare the list and remove excess whitespaces/empty lines.
It is possible to ignore both unused registered accounts *and* old accounts. It is not possible to specify an ignore list for each filter. There is only a generel ignore file.
