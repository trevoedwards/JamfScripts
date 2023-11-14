#!/bin/bash

# credit to iJakes & ubcoit - https://community.jamf.com/t5/jamf-pro/deploying-cisco-amp-v-1-9/m-p/213225
# set $4 to your Cisco AMP Console URL via Policy (ex: https://console.amp.cisco.com/install_packages/REDACTED/download?product=MacProduct)

set -x

ciscoAMPPath="/Applications/Cisco AMP/AMP for Endpoints Connector.app/Contents/Info.plist"
redirectingURL="$4"
localInstallerVolume="/Volumes/ampmac_connector"
localInstallerPackage="ciscoampmac_connector.pkg"
tmpFolder="/Library/CiscoAMPtmp"

checkAndGetURLs()
{
dmgURL=$(curl --head "$redirectingURL" | grep -i "Location:" | awk '{print $2}')
if [[ -z $dmgURL ]]
  then
    echo "Unable to retrieve DMG url. Exiting..."
    exit 1
fi

echo "DMG URL found. Continuing..."

dmgFile=$(basename "$(echo $dmgURL | awk -F '?' '{print $1}')")
dmgName=$(echo "${dmgFile%.*}")
}

downloadInstaller()
{
mkdir -p "$tmpFolder"
echo "Downloading $dmgFile..."
/usr/bin/curl -L -s "$redirectingURL" -o "$tmpFolder"/"$dmgFile" --location-trusted
}

installPackage()
{
if [[ -e "$tmpFolder"/"$dmgFile" ]]
  then
    hdiutil attach "$tmpFolder"/"$dmgFile" -nobrowse -quiet
    if [[ -e "$localInstallerVolume"/"$localInstallerPackage" ]]
      then
        echo "$localInstallerPackage found. Installing..."
        /usr/sbin/installer -pkg "$localInstallerVolume"/"$localInstallerPackage" -target /
        if [[ $(echo $?) -gt 0  ]]
          then
            echo "Installer encountered error. Exiting..."
            hdiutil detach "$localInstallerVolume" -force
            rm -Rf "$tmpFolder"
            exit 1
          else
            echo "Successfully installed "$localInstallerPackage". Exiting..."
            hdiutil detach "$localInstallerVolume" -force
            rm -Rf "$tmpFolder"
            exit 0
        fi
    fi
  else
    echo "$dmgFile failed to download. Exiting..."
    exit 1
fi
}

checkAndGetURLs
downloadInstaller
installPackage
