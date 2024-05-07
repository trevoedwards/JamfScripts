#!/bin/bash
#
####################################################################################################
#
# The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
# MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
# THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
# FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
# OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.
#
# IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
# OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
# MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
# AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
# STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#
####################################################################################################
#
# DESCRIPTION
#	The purpose of this script is to configure the Time Zone and Time Servers.
#
#	When used in a build configuration the script priority must be set to: At Reboot
#
# SYNOPSIS
#	sudo Configure_Time.sh
#	sudo Configure_Time.sh <mountPoint> <computerName> <currentUsername> <TimeZone> <TimeServer1> <TimeServer2> <TimeServer2> <EnableAutoTimeZone>
#
#	If the <EnableAutoTimeZone> parameter to "yes" Location Services will be enabled
#	and the time zone will be set automatically using current location.
#		
#####################################################################################################
#
# DEFINE VARIABLES & READ IN PARAMETERS
#
####################################################################################################
#
# macOS Version
sw_vers_Full=$(/usr/bin/sw_vers -productVersion)
sw_vers_Full_Integer=$(/usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{for(i=1; i<=NF; i++) {printf("%02d",$i)}}')
sw_vers_Major=$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f 1,2)
sw_vers_Major_Integer=$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f 1,2 | /usr/bin/awk -F. '{for(i=1; i<=NF; i++) {printf("%02d",$i)}}')
# Jamf Environmental Positional Variables.
# $1 Mount Point
# $2 Computer Name
# $3 Current User Name - This can only be used with policies triggered by login or logout.
# Declare the Enviromental Positional Variables so the can be used in function calls.
mountPoint=$1
computerName=$2
username=$3
#
# HARDCODED VALUE FOR "TimeZone" IS SET HERE
# Use "/usr/sbin/systemsetup -listtimezones" to see a list of available list time zones.
# TimeZone="Europe/Stockholm"
# TimeZone="Asia/Hong_Kong"
# TimeZone="America/New_York"
# TimeZone="America/Los_Angeles"
TimeZone=""
# CHECK TO SEE IF A VALUE WAS PASSED IN PARAMETER 4 AND, IF SO, ASSIGN TO "TimeZone"
# If a value is specificed via a Jamf policy, it will override the hardcoded value in the script.
if [ "$4" != "" ];then
    TimeZone=$4
fi
#
# HARDCODED VALUE FOR "TimeServers" IS SET HERE
# Time Server 1 (Internal primary if NTP is blocked on corp network)
# TimeServer1="time1.company.com"
TimeServer1=""
# CHECK TO SEE IF A VALUE WAS PASSED IN PARAMETER 5 AND, IF SO, ASSIGN TO "TimeServer1"
# If a value is specificed via a jamf policy, it will override the hardcoded value in the script.
if [ "$5" != "" ];then
    TimeServer1=$5
fi
# Time Server 2
# TimeServer2="time2.company.com"
TimeServer2=""
# CHECK TO SEE IF A VALUE WAS PASSED IN PARAMETER 6 AND, IF SO, ASSIGN TO "TimeServer2"
# If a value is specificed via a Jamf policy, it will override the hardcoded value in the script.
if [ "$6" != "" ];then
    TimeServer2=$6
fi
# External Time Server
# TimeServer3="time.apple.com"
TimeServer3=""
# CHECK TO SEE IF A VALUE WAS PASSED IN PARAMETER 7 AND, IF SO, ASSIGN TO "TimeServer3"
# If a value is specificed via a Jamf policy, it will override the hardcoded value in the script.
if [ "$7" != "" ];then
    TimeServer3=$7
fi
#
# HARDCODED VALUE FOR "EnableAutoTimeZone" IS SET HERE
# set to yes or no
EnableAutoTimeZone="yes"
# CHECK TO SEE IF A VALUE WAS PASSED IN PARAMETER 8 AND, IF SO, ASSIGN TO "EnableAutoTimeZone"
# If a value is specificed via a Jamf policy, it will override the hardcoded value in the script.
if [ "$8" != "" ];then
    EnableAutoTimeZone=$8
fi
#
/bin/echo "$computerName" is running macOS version "$sw_vers_Full"
/bin/echo "TimeZone:	$TimeZone"
/bin/echo "TimeServer1:	$TimeServer1"
/bin/echo "TimeServer2:	$TimeServer2"
/bin/echo "TimeServer3:	$TimeServer3"
/bin/echo "EnableAutoTimeZone:	$EnableAutoTimeZone"
#
#####################################################################################################
#
# Functions to call on
#
####################################################################################################
#
### Ensure we are running this script as root ###
rootcheck () {
if [ "$(/usr/bin/whoami)" != "root" ] ; then
	/bin/echo "This script must be run as root or sudo."
  exit 2
fi
}
###
#
####################################################################################################
# 
# SCRIPT CONTENTS
#
####################################################################################################
rootcheck
/usr/sbin/systemsetup -setusingnetworktime off 
#Set an initial time zone
if [ "$TimeZone" != "" ]; then
	/usr/sbin/systemsetup -settimezone $TimeZone
fi
#Set specific time servers
if [ "$TimeServer1" != "" ]; then
	/usr/sbin/systemsetup -setnetworktimeserver $TimeServer1
	/bin/cat /private/etc/ntp.conf
	/bin/sleep 1
fi
if [ "$TimeServer2" != "" ]; then
	/bin/echo server "${TimeServer2}" >> /private/etc/ntp.conf
	/bin/cat /private/etc/ntp.conf
	/bin/sleep 1
fi
if [ "$TimeServer3" != "" ]; then
	/bin/echo server "${TimeServer3}" >> /private/etc/ntp.conf
	/bin/cat /private/etc/ntp.conf
	/bin/sleep 1
fi
# set time zone automatically using current location 
if [ "$EnableAutoTimeZone" = "yes" ]; then	
	/bin/echo "set time zone automatically using current location"
	
	# write enabled key turn on location services
	/usr/sbin/networksetup -setnetworkserviceenabled "Wi-Fi" on
	/usr/sbin/networksetup -setairportpower "Wi-Fi" on
	uuid=$(/usr/sbin/system_profiler SPHardwareDataType | grep "Hardware UUID" | cut -c22-57)
	/usr/bin/defaults write /var/db/locationd/Library/Preferences/ByHost/com.apple.locationd.$uuid LocationServicesEnabled -bool true
	/usr/bin/defaults write /var/db/locationd/Library/Preferences/ByHost/com.apple.locationd LocationServicesEnabled -bool true
    /usr/bin/killall locationd
    
    # enable icon in menu bar
    /usr/bin/defaults write /Library/Preferences/com.apple.locationmenu "ShowSystemServices" -bool true
    
    # Turn on auto timezone
	/usr/bin/defaults write /Library/Preferences/com.apple.timezone.auto Active -bool true
	/usr/bin/defaults write /private/var/db/timed/Library/Preferences/com.apple.timed.plist TMAutomaticTimeOnlyEnabled -bool true
	/usr/bin/defaults write /private/var/db/timed/Library/Preferences/com.apple.timed.plist TMAutomaticTimeZoneEnabled -bool true
fi
/usr/sbin/systemsetup -setusingnetworktime on 
/usr/sbin/systemsetup -gettimezone
/usr/sbin/systemsetup -getnetworktimeserver
/bin/cat /private/etc/ntp.conf
exit 0
