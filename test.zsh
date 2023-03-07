# Dockutil Installation
name="dockutil"
echo "$name check for installation"
# download URL, version and Expected Team ID
# Method for GitHub pkg w. app version check
gitusername="kcrawford"
gitreponame="dockutil"
#echo "$gitusername $gitreponame"
filetype="pkg"
downloadURL=$(curl -sfL "https://api.github.com/repos/$gitusername/$gitreponame/releases/latest" | awk -F '"' "/browser_download_url/ && /$filetype\"/ { print \$4; exit }")
if [[ "$(echo $downloadURL | grep -ioE "https.*.$filetype")" == "" ]]; then
    printlog "GitHub API failed, trying failover."
    #downloadURL="https://github.com$(curl -sfL "https://github.com/$gitusername/$gitreponame/releases/latest" | tr '"' "\n" | grep -i "^/.*\/releases\/download\/.*\.$filetype" | head -1)"
    downloadURL="https://github.com$(curl -sfL "$(curl -sfL "https://github.com/$gitusername/$gitreponame/releases/latest" | tr '"' "\n" | grep -i "expanded_assets" | head -1)" | tr '"' "\n" | grep -i "^/.*\/releases\/download\/.*\.$filetype" | head -1)"
fi
#echo "$downloadURL"
appNewVersion=$(curl -sLI "https://github.com/$gitusername/$gitreponame/releases/latest" | grep -i "^location" | tr "/" "\n" | tail -1 | sed 's/[^0-9\.]//g')
#echo "$appNewVersion"
expectedTeamID="Z5J8CJBUWC"
destFile="/usr/local/bin/dockutil"

echo "$name not found or version not latest..."
echo "${destFile}"
echo "Installing version ${appNewVersion}..."

# Create temporary working directory
tmpDir="$(mktemp -d || true)"
echo "Created working directory '$tmpDir'"

# Download the installer package
echo "Downloading $name package version $appNewVersion from: $downloadURL"

# Verify the download
echo "Download $name success..."

# Install the package
echo "Installing package: '$tmpDir/$name.pkg'."
pkgInstall=$(installer -verbose -dumplog -pkg "$tmpDir/$name.pkg" -target "/" 2>&1)
pkgInstallStatus=$(echo $?)
if [[ $pkgInstallStatus -ne 0 ]]; then
    echo "ERROR. $name package installation failed."
    echo "${pkgInstall}"
    exitCode=2
        else
            echo "$name installation successful..."
            exitCode=0
fi

# Remove the temporary working directory
echo "Deleting working directory '$tmpDir' and its contents."
echo "Remove $(rm -Rfv "${tmpDir}" || true)"
