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
# ABOUT THIS PROGRAM
#
# NAME
#	Configure_ComputerName_SN.sh
#
#	The purpose of this script is to name the computer based on the truncated serial number and a prefix.
#
#	This can be used in an "On Enrollment" policy. 
#
####################################################################################################
#
# DEFINE VARIABLES & READ IN PARAMETERS
#
####################################################################################################
# HARDCODED VALUES ARE SET HERE
# Jamf Environmental Positional Variables.
# $1 Mount Point
# $2 Computer Name
# $3 Current User Name - This can only be used with policies triggered by login or logout.
# Declare the Enviromental Positional Variables so the can be used in function calls.
mountPoint=$1
computerName=$2
username=$3
#Get computer serial number
SerialNumber="$(/usr/sbin/system_profiler SPHardwareDataType | grep "Serial Number (system)" | awk '{print $4}')"
#Determine Laptop or Desktop or RackMount or Virtual
HWModel="$(/usr/sbin/system_profiler SPHardwareDataType | grep Model\ Name)"
SPHardwareDataType_AppleROMInfo=$(/usr/sbin/system_profiler SPHardwareDataType 2> /dev/null | /usr/bin/grep "Apple ROM Info")
SPHardwareDataType_Enclosure=$(/usr/sbin/system_profiler SPHardwareDataType 2> /dev/null | /usr/bin/grep "Enclosure")
if [[ $SPHardwareDataType_AppleROMInfo == *"Virtual"* ]]; then
	MV_or_MR_or_ML_or_MD="MV"
elif [[ $SPHardwareDataType_Enclosure == *"Rack"* ]]; then
	MV_or_MR_or_ML_or_MD="MR"
elif [[ $HWModel == *"Book"* ]]; then
	MV_or_MR_or_ML_or_MD="ML"
else 
	MV_or_MR_or_ML_or_MD="MD"
fi

#Truncate SN last 8 from SN -1
TruncatedSN="${SerialNumber:$((${#str}-8)):8}"
# HARDCODED VALUE FOR "Prefix" IS SET HERE
Prefix=""
# CHECK TO SEE IF A VALUE WAS PASSED IN PARAMETER 4 AND, IF SO, ASSIGN TO "Prefix"
# If a value is specified via a Jamf policy, it will override the hardcoded value in the script.
if [ "$4" != "" ];then
    Prefix=$4
fi
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
  exit 0
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
#NewComputerName="$SerialNumber"
NewComputerName="${Prefix}${TruncatedSN}"
#NewComputerName="$TruncatedSN"
#NewComputerName="$MV_or_MR_or_ML_or_MD""-""$SerialNumber"
/bin/echo "NewComputerName is $NewComputerName"
jamf setComputerName -name "$NewComputerName"
/usr/sbin/scutil --set ComputerName "$NewComputerName"
/usr/sbin/scutil --get ComputerName
/usr/sbin/scutil --set LocalHostName "$NewComputerName"
/usr/sbin/scutil --get LocalHostName
/usr/sbin/scutil --set HostName "$NewComputerName"
/usr/sbin/scutil --get HostName
/bin/mkdir -p /private/var/EnterpriseManagement/
/usr/bin/defaults write "/private/var/EnterpriseManagement/com.apple.enterprisedeployment" originalComputerName -string "$NewComputerName"
/usr/bin/killall cfprefsd
jamf recon
exit 0
