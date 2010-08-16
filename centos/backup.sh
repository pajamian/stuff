#!/bin/sh
#
# Backup script for servers.  This uses rsync to backup to a ssh account on a remote server.
#
# Written by Peter Ajamian <peter@pajamian.dhs.org>
#

# Configuration file default location
if [ ! "$BACKUP_CONF" ]; then
    BACKUP_CONF=/etc/backup/backup.conf
fi

if [ ! -e "$BACKUP_CONF" ]; then
    echo "Configuration file $BACKUP_CONF not found.  Exiting."
    exit
fi

# Import the configuration settings.
. "$BACKUP_CONF"

# Get list of domains to backup
domlist=`ls -1 $domuconfig | grep -vP "$domuexclude"`

# Make sure there is enough space on the backup server
while ssh a1825@backup 'df -PB1G .' | perl -le 'exit((split /\s+/, (<STDIN>)[1])[3] < $ARGV[0] ? 0 : 1)' $minsize; do
    # We need to make some room, get rid of old backups, daily first then weekly then monthly
    ssh $sshlogin "
	if [[ -n \`ls -1 '$remotepath/daily/'\` ]]; then
		rm -rf \`ls -1d '$remotepath/daily/'* | head -1\`
	elif [[ -n \`ls -1 '$remotepath/weekly/'\` ]]; then
		rm -rf \`ls -1d '$remotepath/weekly/'* | head -1\`
	else
		rm -rf \`ls -1d '$remotepath/monthly/'* | head -1\`
	fi
    "
done

# Copy the target using links.
now=`date +%Y%m%d%H%M%S`
sunday=`date +%Y%m%d000000 -d 'next sun - 1 week'`
month=`date +%Y%m00000000`
rpath="$remotepath/daily/$now"
ssh "$sshlogin" "cp -al \`ls -1d '$remotepath/daily/'* | tail -1\` '$rpath'" 2>/dev/null

for dom in dom0 $domlist; do
    if [[ $dom == 'dom0' ]]; then
	# We don't have to mount dom0 but it's in a different location
	lpath="$localpath"
    else
	# Create a snapshot and mount it
	umount -l "$domumount" 2>/dev/null
	lvcreate -L10G -n "$snapvol" -s "$lvpath/$dom" >/dev/null
	mount "$lvpath/$snapvol" "$domumount"
	lpath="$domumount/"
    fi

    # Create an owner/permissions tree file that we can use later on to restore permissions/ownership of files:
    # The basic format is a tab delimited file with the following fields:
    # permissions, userid, username, groupid, groupname, file path and name.
    # The file path and name are the last field so that tabs can be included in the filename if needed.
    mkdir -p "$lpath/$backdir"
    umask 077
    find "$lpath" -printf '%#m\t%u\t%U\t%g\t%G\t%p\n' > "$lpath$permtree" 2>/dev/null

    # Use rsync to update the new files
    ssh "$sshlogin" "mkdir -p $rpath/$dom/"
    rsync -aHz --chmod=Du+rwx,Fu+rw --delete --delete-excluded --exclude-from="$exclude" $BACKUP_EXTRA "$lpath" "$sshlogin:$rpath/$dom/"

    if [[ $dom != 'dom0' ]]; then
    # Unmount the snapshot and delete it.
	umount -l $domumount
	lvremove -f $lvpath/$snapvol >/dev/null
    fi
done


# Rest is done on the remote server
ssh "$sshlogin" "
	# Purge extra daily backups
	rm -rf \`ls -1d '$remotepath/daily/'* | head -n-$daily\` 2>/dev/null

	# Check to see if this is the first backup of the week and copy to a weekly backup if so
	if [[ -z \`ls -1 $remotepath/weekly/\` || \`ls -1 $remotepath/weekly/ | tail -1\` -lt $sunday ]]; then
		# Copy the backup
		cp -al '$rpath' '$remotepath/weekly/$now'

		# Purge extra weekly backups
		rm -rf \`ls -1d '$remotepath/weekly/'* | head -n-$weekly\` 2>/dev/null

		# Check to see if this is the first backup of the month and copy to a monthly backup if so
		if [[ -z \`ls -1 $remotepath/monthly/\` || \`ls -1 $remotepath/monthly/ | tail -1\` -lt $month ]]; then
			# Copy the backup
			cp -al '$rpath' '$remotepath/monthly/$now'

			# Purge extra monthly backups
			rm -rf \`ls -1d '$remotepath/monthly/'* | head -n-$monthly\` 2>/dev/null
		fi
	fi
"

# Backup Complete!

# TODO:
# Write a decent restore script.  Since ownership cannot be preserved in the destination files, and
# all directories are set u+rwx and all files u+rw, the restore script should use the permissions
# tree file to restore proper ownership and permissions to files after rsyncing them back.
