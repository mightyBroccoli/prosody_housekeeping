#!/bin/bash

#
# housecleaning script for prosody
#

###### CONFIGURATION ######
# configuration variables
tmp_directory=/tmp/prosody/
junk_to_delete=$tmp_directory/accounts_to_delete.txt

host="magicbroccoli.de"
# maximum timeframe for accounts registered but not logged in
# needs to be in the syntax 1day 2weeks 3months 4years
unused_accounts_timeframe="14days"
# maxium timeframe for accounts since last login
old_accounts_timeframe="1year"

# maximum age of mod_mam messags stored in the database
enable_mam_clearing=false
# needs to be in mysql syntax 1 DAY 2 MONTH 3 YEAR
mam_message_live="2 MONTH"

# prosody mysql login credentials
prosody_db_user="prosody"
prosody_db_password="super_secret-password1337"

# http upload path
http_upload_path="/var/lib/prosody/http_upload"
# http upload lifetime in days
http_upload_expire="31"

###### PRE RUN FUNCTION SECTION ######
prerun_check()
{
	#check if tmp directory is present if not create it
	if [ ! -d "$tmp_directory" ]; then
		mkdir -p $tmp_directory
	fi

	# clear env
	clearcomp
}

clearcomp()
{
	if [ "$1" = "-all" ]; then
		# run the created script to delete the selected accounts
		bash $junk_to_delete

		#remove all tmp files and variables for privacy reasons
		rm -f "$junk_to_delete"
		unset unused_accounts_timeframe old_accounts_timeframe host mam_message_live enable_mam_clearing prosody_db_user prosody_db_password junk_to_delete
	fi

	# remove the temp files
	rm -f "$junk_to_delete"
}

catch_help()
{
	# catch  -h / --help
	if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
		display_help
		exit
	fi
}

catch_configtest()
{
	# test your configuration first to see what would have be deleted
	if [ "$1" == "-t" ] || [ "$1" == "--configtest" ]; then
		filter_unused_accounts
		filter_old_accounts
		filter_mam_messages --test

		cat $junk_to_delete
		exit
	fi
}

###### FILTER SECTION ######
filter_unused_accounts()
{
	# filter all registered but not logged in accounts older then $unused_accounts_timeframe
	prosodyctl mod_list_inactive $host "$unused_accounts_timeframe" event | grep registered | sed 's/registered//g' | sed -e 's/^/prosodyctl deluser /' >> $junk_to_delete
}

filter_old_accounts()
{
	# filter all inactive accounts older then $old_accounts_timeframe
	prosodyctl mod_list_inactive $host "$old_accounts_timeframe" | sed -e 's/^/prosodyctl deluser /' >> $junk_to_delete
}

filter_mam_messages()
{
	# only run this filter if $enable_mam_clearing is set to true
	if [ "$enable_mam_clearing" = "true" ]; then
		# catch config test
		if [ "$1" = "--test" ]; then
			# this is currently a workaround caused by the extrem slowness of prosodys own clearing mechanism
			# filter all expired mod_mam messages from archive
			echo "SELECT * FROM prosody.prosodyarchive WHERE \`when\` < UNIX_TIMESTAMP(DATE_SUB(curdate(),INTERVAL $mam_message_live));" | mysql -u $prosody_db_user -p$prosody_db_password &>> $junk_to_delete
			return 1
		fi
		# this is currently a workaround caused by the extrem slowness of prosodys own clearing mechanism
		# delete all expired mod_mam messages from archive
		echo "DELETE FROM prosody.prosodyarchive WHERE \`when\` < UNIX_TIMESTAMP(DATE_SUB(curdate(),INTERVAL $mam_message_live));" | mysql -u $prosody_db_user -p$prosody_db_password
	fi
}

filter_expired_http_uploads()
{
	# currently a workaround as the mod_http_uploud is not removing the folder which holds the file
	find $http_upload_path/* -maxdepth 0 -type d -mtime +$http_upload_expire | sed -e 's/^/rm -rf /' >> $junk_to_delete
}

###### General Functions ######
display_help()
{
	echo -e "Prosody housecleaning script"
	echo -e "Workflow"
	echo -e "1. Filter registered but unused accounts from Database \n2. Filter Account that have been inactive for too long\n3. Remove expired Messaged from Prosodys MAM from the Database\n4. Remove the selected Accounts\n"
	echo -e "There are some major variables needed to be set:"
	echo -e "1. maximum age of registered but unused accounts\n2. maximum age of unused accounts\n3. maximum age of mod_mam records\n4. Prosodys Database login credentials"
}

###### MAIN CODE SECTION ######
# catch user help input
catch_help "$@"
# check env and some tests
prerun_check
# catch user config test
catch_configtest "$@"

# unused accounts filter
filter_unused_accounts
# old accounts filter
filter_old_accounts
# epired mod_mam filter
filter_mam_messages

# final step cleanup
clearcomp -all
