#!/bin/bash

if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

MOUNT_POINT="/mnt/nas"
SHARE_NAME="nas"
USER_NAME="pi"
GROUP_NAME="pi"

echo "Updating and upgrading Raspberry Pi OS..."
apt-get update && apt-get upgrade -y

echo "Installing essential system packages including Python..."
apt-get install python3-pip python3-venv samba samba-common-bin -y

echo "Installing Plex Media Server..."
curl https://downloads.plex.tv/plex-keys/PlexSign.key | apt-key add -
echo deb https://downloads.plex.tv/repo/deb public main | tee /etc/apt/sources.list.d/plexmediaserver.list
apt-get update
apt-get install plexmediaserver -y

echo "Detecting connected external drives..."
lsblk -o NAME,SIZE,MODEL -dp | grep -v "boot\|root"
echo "Please enter the device name to use (e.g., /dev/sda):"
read -r SSD_DEVICE

if [ -z "$SSD_DEVICE" ]; then
    echo "No drive specified. Exiting."
    exit 1
fi

echo "Drive selected: $SSD_DEVICE"

echo "WARNING: This will format $SSD_DEVICE as Ext4, erasing all data. Proceed? (y/n)"
read -r proceed
if [ "$proceed" != "y" ]; then
    echo "Operation cancelled."
    exit 1
fi

echo "Formatting the SSD to Ext4..."
mkfs.ext4 $SSD_DEVICE

echo "Creating mount point at $MOUNT_POINT"
mkdir -p $MOUNT_POINT
UUID=$(blkid -o value -s UUID $SSD_DEVICE)
echo "UUID=$UUID $MOUNT_POINT ext4 defaults,auto,users,rw,nofail 0 0" >> /etc/fstab

echo "Mounting the SSD..."
mount -a

echo "Configuring Samba Share named $SHARE_NAME for $MOUNT_POINT..."
cat >> /etc/samba/smb.conf <<EOT
[$SHARE_NAME]
path = $MOUNT_POINT
writeable=Yes
create mask=0777
directory mask=0777
public=yes
browsable=yes
guest ok=yes
force user=$USER_NAME
force group=$GROUP_NAME
EOT

echo "Restarting Samba..."
systemctl restart smbd

echo "Setting up Home Webapp Service..."
git clone https://github.com/MrLately/pi-service-dashboard /home/pi/pi-service-dashboard
python3 -m venv /home/pi/pi-service-dashboard/venv
source /home/pi/pi-service-dashboard/venv/bin/activate
pip install Flask psutil
deactivate

ServiceFile="/etc/systemd/system/homepage.service"
echo "Creating systemd service file at $ServiceFile"
cat > $ServiceFile << EOF
[Unit]
Description=Home Page Service
After=network.target

[Service]
Type=simple
User=pi
Group=pi
WorkingDirectory=/home/pi/pi-service-dashboard
ExecStart=/home/pi/pi-service-dashboard/venv/bin/python3 home_os/home.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable homepage.service
systemctl start homepage.service

echo "Installing FileBrowser..."
bash <(curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh)
cat > /etc/systemd/system/filebrowser.service << EOF
[Unit]
Description=FileBrowser
After=network.target

[Service]
User=pi
Group=pi
ExecStart=/usr/local/bin/filebrowser -r /mnt/nas -p 8080 -d /home/pi/.filebrowser/database.db -b /filebrowser -a 0.0.0.0
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable filebrowser.service
systemctl start filebrowser.service

echo "owning nas..."
sudo chown -R pi:pi /mnt/nas
sudo chmod -R 775 /mnt/nas

echo "Installing Pi-hole..."
git clone --depth 1 https://github.com/pi-hole/pi-hole.git Pi-hole
cd "Pi-hole/automated install/"
sudo bash basic-install.sh

