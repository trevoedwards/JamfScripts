#!/bin/bash

# Example local management account called "jamf", in Jamf Pro the custom script parameters start at $4, 
# so you should substitute $4 and $5 in the script body and potentially more for users you DO NOT want to demote.

adminUsers=$(dscl . -read Groups/admin GroupMembership | cut -c 18-)

for user in $adminUsers
do
	if [ "$user" != "root" ]  && [ "$user" != "jamf" ] && [ "$user" != "$4" ] && [ "$user" != "$5" ]
	then 
		dseditgroup -o edit -d $user -t user admin
		if [ $? = 0 ]; then echo "Removed user $user from admin group"; fi
	else
		echo "Admin user $user left alone"
	fi
done
