#!/bin/bash

dirbash=/srv/http/bash
dirdata=/srv/http/data
dirsystem=$dirdata/system
dirtmp=$dirdata/shm
filebootlog=$dirdata/tmp/bootlog
filereboot=$dirtmp/reboot
fileconfig=/boot/config.txt
filemodule=/etc/modules-load.d/raspberrypi.conf

# convert each line to each args
readarray -t args <<< "$1"

pushstream() {
	curl -s -X POST http://127.0.0.1/pub?id=$1 -d "$2"
}
pushRefresh() {
	data=$( /srv/http/bash/system-data.sh )
	pushstream refresh "$data"
}
relaysOrder() {
	conf=$( cat /etc/relays.conf )
	data() {
		grep "$1" <<< "$conf" | awk '{print $NF}' | tr -d , | tr '\n' ' '
	}
	on=( $( data '"on."' ) )
	ond=( $( data '"ond."' ) )
	off=( $( data '"off."' ) )
	offd=( $( data '"offd."' ) )
	timer=$( grep '"timer"' <<< "$conf" | awk '{print $NF}' )
	relaysfile='/srv/http/data/shm/relaystimer'

	name=$( grep -A4 '"name"' <<< "$conf" | tail -4 )
	readarray -t pins <<< $( echo "$name" | cut -d'"' -f2 )
	readarray -t names <<< $( echo "$name" | cut -d'"' -f4 )
	declare -A pinname
	for i in 0 1 2 3; do
		pinname+=( [${pins[$i]}]=${names[$i]} )
	done
	for i in 0 1 2 3; do
		oni=${on[$i]}
		offi=${off[$i]}
		[[ $oni != 0 ]] && onorder+=,'"'${pinname[$oni]}'"'
		[[ $offi != 0 ]] && offorder+=,'"'${pinname[$offi]}'"'
	done

	declare -p pinname > $dirsystem/relays
	echo -n "\
onorder='[ ${onorder:1} ]'
on=( $( data '"on."' ) )
ond=( $( data '"ond."' ) )
offorder='[ ${offorder:1} ]'
off=( $( data '"off."' ) )
offd=( $( data '"offd."' ) )
timer=$timer
" >> $dirsystem/relays
}
soundprofile() {
	if [[ $1 == reset ]]; then
		latency=18000000
		swappiness=60
		mtu=1500
		txqueuelen=1000
		rm -f $dirsystem/soundprofile
	else
		. /etc/soundprofile.conf
		touch $dirsystem/soundprofile
	fi

	sysctl kernel.sched_latency_ns=$latency
	sysctl vm.swappiness=$swappiness
	if ifconfig | grep -q eth0; then
		ip link set eth0 mtu $mtu
		ip link set eth0 txqueuelen $txqueuelen
	fi
}

case ${args[0]} in

bluetooth )
	sleep 3
	[[ -e $dirsystem/btdiscoverable ]] && yesno=yes || yesno=no
	bluetoothctl discoverable $yesno &
	bluetoothctl discoverable-timeout 0 &
	bluetoothctl pairable yes &
	;;
bluetoothdisable )
	systemctl disable --now bluetooth
	pushRefresh
	;;
bluetoothset )
	btdiscoverable=${args[1]}
	btformat=${args[2]}
	if [[ $btdiscoverable == true ]]; then
		yesno=yes
		touch $dirsystem/btdiscoverable
	else
		yesno=no
		rm $dirsystem/btdiscoverable
	fi
	if ! systemctl -q is-active bluetooth; then
		systemctl enable --now bluetooth
		sleep 3
	fi
	bluetoothctl discoverable $yesno &
	[[ $btformat == true ]] && touch $dirsystem/btformat || rm $dirsystem/btformat
	pushRefresh
	;;
databackup )
	dirconfig=$dirdata/config
	backupfile=$dirdata/tmp/backup.gz
	rm -f $backupfile
	alsactl store
	files=(
/boot/cmdline.txt
/boot/config.txt
/etc/conf.d/wireless-regdom
/etc/default/snapclient
/etc/hostapd/hostapd.conf
/etc/samba/smb.conf
/etc/systemd/network/eth0.network
/etc/systemd/timesyncd.conf
/etc/X11/xorg.conf.d/99-calibration.conf
/etc/X11/xorg.conf.d/99-raspi-rotate.conf
/etc/fstab
/etc/lcdchar.conf
/etc/localbrowser.conf
/etc/mpd.conf
/etc/mpdscribble.conf
/etc/powerbutton.conf
/etc/relays.conf
/etc/soundprofile.conf
/etc/upmpdcli.conf
/var/lib/alsa/asound.state
)
	for file in ${files[@]}; do
		if [[ -e $file ]]; then
			mkdir -p $dirconfig/$( dirname $file )
			cp {,$dirconfig}$file
		fi
	done
	hostname > $dirsystem/hostname
	timedatectl | awk '/zone:/ {print $3}' > $dirsystem/timezone
	readarray -t profiles <<< $( ls -p /etc/netctl | grep -v / )
	if [[ -n $profiles ]]; then
		cp -r /etc/netctl $dirconfig/etc
		for profile in "${profiles[@]}"; do
			if [[ $( netctl is-enabled "$profile" ) == enabled ]]; then
				echo $profile > $dirsystem/netctlprofile
				break
			fi
		done
	fi
	mkdir -p $dirconfig/var/lib
	cp -r /var/lib/bluetooth $dirconfig/var/lib &> /dev/null
	
	services='bluetooth hostapd localbrowser mpdscribble@mpd powerbutton shairport-sync smb snapclient snapserver spotifyd upmpdcli'
	for service in $services; do
		systemctl -q is-active $service && enable+=" $service" || disable+=" $service"
	done
	[[ -n $enable ]] && echo $enable > $dirsystem/enable
	[[ -n $disable ]] && echo $disable > $dirsystem/disable
	
	bsdtar \
		--exclude './addons' \
		--exclude './embedded' \
		--exclude './shm' \
		--exclude './system/version' \
		--exclude './tmp' \
		-czf $backupfile \
		-C /srv/http \
		data \
		2> /dev/null && echo 1
	
	rm -rf $dirdata/{config,disable,enable}
	;;
datarestore )
	backupfile=$dirdata/tmp/backup.gz
	dirconfig=$dirdata/config
	systemctl stop mpd
	# remove all flags
	rm -f $dirsystem/{autoplay,login*}                          # features
	rm -f $dirsystem/{crossfade*,custom*,dop*,mixertype*,soxr*} # mpd
	rm -f $dirsystem/{updating,listing}                         # updating_db
	rm -f $dirsystem/{color,relays,soundprofile}                # system
	
	bsdtar -xpf $backupfile -C /srv/http
	
	uuid1=$( head -1 /etc/fstab | cut -d' ' -f1 )
	uuid2=${uuid1:0:-1}2
	sed -i "s/root=.* rw/root=$uuid2 rw/; s/elevator=noop //" $dirconfig/boot/cmdline.txt
	sed -i "s/^PARTUUID=.*-01  /$uuid1  /; s/^PARTUUID=.*-02  /$uuid2  /" $dirconfig/etc/fstab
	
	rm -f $dirconfig/etc/{shairport-sync,spotifyd}.conf # temp: for ealier version
	cp -rf $dirconfig/* /
	[[ -e $dirsystem/enable ]] && systemctl -q enable $( cat $dirsystem/enable )
	[[ -e $dirsystem/disable ]] && systemctl -q disable $( cat $dirsystem/disable )
	hostnamectl set-hostname $( cat $dirsystem/hostname )
	[[ -e $dirsystem/netctlprofile ]] && netctl enable "$( cat $dirsystem/netctlprofile )"
	timedatectl set-timezone $( cat $dirsystem/timezone )
	rm -rf $backupfile $dirconfig $dirsystem/{enable,disable,hostname,netctlprofile,timezone}
	chown -R http:http /srv/http
	chown mpd:audio $dirdata/mpd/mpd* &> /dev/null
	chmod 755 /srv/http/* $dirbash/* /srv/http/settings/*
	[[ -e $dirsystem/crossfade ]] && mpc crossfade $( cat $dirsystem/crossfadeset )
	rmdir /mnt/MPD/NAS/* &> /dev/null
	readarray -t mountpoints <<< $( grep /mnt/MPD/NAS /etc/fstab | awk '{print $2}' | sed 's/\\040/ /g' )
	if [[ -n $mountpoints ]]; then
		for mountpoint in $mountpoints; do
			mkdir -p "$mountpoint"
		done
	fi
	[[ -e $dirsystem/color ]] && /srv/http/bash/cmd.sh color
	/srv/http/bash/cmd.sh power
	;;
getjournalctl )
	if grep -q 'Startup finished.*kernel' $filebootlog &> /devnull; then
		cat "$filebootlog"
	else
		data='{ "title":"Boot Log","text":"Get ...","icon":"plus-r" }'
		pushstream notify "$data"
		journalctl -b | sed -n '1,/Startup finished.*kernel/ p' | tee $filebootlog
	fi
	;;
hostname )
	hostname=${args[1]}
	hostnamectl set-hostname $hostname
	sed -i "s/^\(ssid=\).*/\1${args[1]}/" /etc/hostapd/hostapd.conf
	sed -i '/^\tname =/ s/".*"/"'$hostname'"/' /etc/shairport-sync.conf
	sed -i "s/^\(friendlyname = \).*/\1${args[1]}/" /etc/upmpdcli.conf
	rm -f /root/.config/chromium/SingletonLock 	# 7" display might need to rm: SingletonCookie SingletonSocket
	systemctl try-restart avahi-daemon bluetooth hostapd localbrowser mpd smb shairport-sync shairport-meta spotifyd upmpdcli
	pushRefresh
	;;
i2smodule )
	aplayname=${args[1]}
	output=${args[2]}
	reboot=${args[3]}
	dtoverlay=$( grep 'dtparam=i2c_arm=on\|dtparam=krnbt=on\|dtparam=spi=on\|dtoverlay=gpio\|dtoverlay=sdtweak,poll_once\|waveshare\|tft35a\|hdmi_force_hotplug=1' $fileconfig )
	if [[ $aplayname != onboard ]]; then
		dtoverlay+="
dtparam=i2s=on
dtoverlay=$aplayname"
		[[ $output == 'Pimoroni Audio DAC SHIM' ]] && dtoverlay+="
gpio=25=op,dh"
		[[ $aplayname == rpi-cirrus-wm5102 ]] && echo softdep arizona-spi pre: arizona-ldo1 > /etc/modprobe.d/cirrus.conf
	else
		dtoverlay+="
dtparam=audio=on"
		revision=$( awk '/Revision/ {print $NF}' /proc/cpuinfo )
		revision=${revision: -3:2}
		[[ $revision == 09 || $revision == 0c ]] && output='HDMI 1' || output=Headphones
		aplayname="bcm2835 $output"
		output="On-board - $output"
		rm -f $dirsystem/audio-* /etc/modprobe.d/cirrus.conf
	fi
	sed -i '/dtparam=\|dtoverlay=\|gpio=25=op,dh\|^$/ d' $fileconfig
	echo "$dtoverlay" >> $fileconfig
	echo $aplayname > $dirsystem/audio-aplayname
	echo $output > $dirsystem/audio-output
	echo "$reboot" > $filereboot
	pushRefresh
	;;
lcdcalibrate )
	degree=$( grep rotate $fileconfig | cut -d= -f3 )
	cp -f /etc/X11/{lcd$degree,xorg.conf.d/99-calibration.conf}
	systemctl stop localbrowser
	value=$( DISPLAY=:0 xinput_calibrator | grep Calibration | cut -d'"' -f4 )
	if [[ -n $value ]]; then
		sed -i "s/\(Calibration\"  \"\).*/\1$value\"/" /etc/X11/xorg.conf.d/99-calibration.conf
		systemctl start localbrowser
	fi
	;;
lcdchardisable )
	if [[ ! -e $dirsystem/lcd ]]; then
		sed -i '/dtparam=i2c_arm=on/ d' $fileconfig
		sed -i '/i2c-bcm2708\|i2c-dev/ d' $filemodule
	fi
	rm $dirsystem/lcdchar
	pushRefresh
	;;
lcdcharset )
	# 0cols 1charmap 2inf 3i2caddress 4i2cchip 5pin_rs 6pin_rw 7pin_e 8pins_data 9backlight
	conf="\
[var]
cols=${args[1]}
charmap=${args[2]}"
	if [[ ${args[3]} == i2c ]]; then
		conf+="
address=${args[4]}
chip=${args[5]}"
		if ! grep -q 'dtparam=i2c_arm=on' $fileconfig; then
			sed -i '$ a\dtparam=i2c_arm=on' $fileconfig
			echo "\
i2c-bcm2708
i2c-dev" >> $filemodule
			echo ${args[11]} > $filereboot
		fi
	else
		conf+="
pin_rs=${args[6]}
pin_rw=${args[7]}
pin_e=${args[8]}
pins_data=${args[9]}"
		if ! grep -q 'waveshare\|tft35a' $fileconfig; then
			sed -i '/dtparam=i2c_arm=on/ d' $fileconfig
			sed -i '/i2c-bcm2708\|i2c-dev/ d' $filemodule
		fi
	fi
	conf+="
backlight=${args[10]^}"
	echo "$conf" > /etc/lcdchar.conf
	touch $dirsystem/lcdchar
	pushRefresh
	;;
lcddisable )
	sed -i 's/ fbcon=map:10 fbcon=font:ProFont6x11//' /boot/cmdline.txt
	sed -i '/hdmi_force_hotplug\|i2c_arm=on\|spi=on\|rotate=/ d' $fileconfig
	sed -i '/i2c-bcm2708\|i2c-dev/ d' $filemodule
	sed -i 's/fb1/fb0/' /etc/X11/xorg.conf.d/99-fbturbo.conf
	pushRefresh
	;;
lcdset )
	model=${args[1]}
	reboot=${args[2]}
	if [[ $model != tft35a ]]; then
		echo $model > /srv/http/data/system/lcdmodel
	else
		rm /srv/http/data/system/lcdmodel
	fi
	sed -i '1 s/$/ fbcon=map:10 fbcon=font:ProFont6x11/' /boot/cmdline.txt
	config="\
hdmi_force_hotplug=1
dtparam=spi=on
dtoverlay=$model:rotate=0"
	! grep -q 'dtparam=i2c_arm=on' $fileconfig && config+="
dtparam=i2c_arm=on"
	echo -n "$config" >> $fileconfig
	! grep -q 'i2c-bcm2708' $filemodule && echo -n "\
i2c-bcm2708
i2c-dev
" >> $filemodule
	cp -f /etc/X11/{lcd0,xorg.conf.d/99-calibration.conf}
	sed -i 's/fb0/fb1/' /etc/X11/xorg.conf.d/99-fbturbo.conf
	systemctl enable localbrower
	[[ -n $rebbot ]] && echo "$reboot" > $filereboot
	pushRefresh
	;;
mount )
	protocol=${args[1]}
	mountpoint="/mnt/MPD/NAS/${args[2]}"
	ip=${args[3]}
	directory=${args[4]}
	user=${args[5]}
	password=${args[6]}
	extraoptions=${args[7]}
	update=${args[8]}

	! ping -c 1 -w 1 $ip &> /dev/null && echo "IP <code>$ip</code> not found." && exit

	if [[ -e $mountpoint ]]; then
		find "$mountpoint" -mindepth 1 | read && echo "Mount name <code>$mountpoint</code> not empty." && exit
	else
		mkdir "$mountpoint"
	fi
	chown mpd:audio "$mountpoint"
	if [[ $protocol == cifs ]]; then
		source="//$ip/$directory"
		options=noauto
		if [[ -z $user ]]; then
			options+=,username=guest
		else
			options+=",username=$user,password=$password"
		fi
		options+=,uid=$( id -u mpd ),gid=$( id -g mpd ),iocharset=utf8
	else
		source="$ip:$directory"
		options=defaults,noauto,bg,soft,timeo=5
	fi
	[[ -n $extraoptions ]] && options+=,$extraoptions
	echo "${source// /\\040}  ${mountpoint// /\\040}  $protocol  ${options// /\\040}  0  0" >> /etc/fstab
	std=$( mount "$mountpoint" 2>&1 )
	if [[ $? == 0 ]]; then
		[[ $update == true ]] && /srv/http/bash/cmd.sh mpcupdate$'\n'"${mountpoint:9}"  # /mnt/MPD/NAS/... > NAS/...
		pushRefresh
	else
		echo "Mount <code>$source</code> failed.<br>"$( echo "$std" | head -1 | sed 's/.*: //' )
		sed -i "\|${mountpoint// /\\040}| d" /etc/fstab
		rmdir "$mountpoint"
	fi
	;;
powerbuttondisable )
	systemctl disable --now powerbutton
	gpio -1 write $( grep led /etc/powerbutton.conf | cut -d= -f2 ) 0
	pushRefresh
	;;
powerbuttonset )
	echo "\
sw=${args[1]}
led=${args[2]}" > /etc/powerbutton.conf
	systemctl restart powerbutton
	systemctl enable powerbutton
	pushRefresh
	;;
regional )
	ntp=${args[1]}
	regom=${args[2]}
	sed -i "s/^\(NTP=\).*/\1$ntp/" /etc/systemd/timesyncd.conf
	sed -i 's/".*"/"'$regdom'"/' /etc/conf.d/wireless-regdom
	iw reg set $regdom
	pushRefresh
	;;
relays )
	[[ ${args[1]} == true ]] && relaysOrder || rm -f $dirsystem/relays
	pushRefresh
	;;
relayssave )
	echo ${args[1]} | jq . > /etc/relays.conf
	relaysOrder
	;;
remount )
	mountpoint=${args[1]}
	source=${args[2]}
	if [[ ${mountpoint:9:3} == NAS ]]; then
		mount "$mountpoint"
	else
		udevil mount "$source"
	fi
	pushRefresh
	;;
remove )
	mountpoint=${args[1]}
	umount -l "$mountpoint"
	rmdir "$mountpoint" &> /dev/null
	sed -i "\|${mountpoint// /\\\\040}| d" /etc/fstab
	/srv/http/bash/cmd.sh mpcupdate$'\n'NAS
	pushRefresh
	;;
soundprofile )
	soundprofile
	;;
soundprofiledisable )
	soundprofile reset
	pushRefresh
	;;
soundprofileget )
	val+=$( sysctl kernel.sched_latency_ns )$'\n'
	val+=$( sysctl vm.swappiness )$'\n'
	ifconfig | grep -q eth0 && val+=$( ifconfig eth0 \
										| grep 'mtu\|txq' \
										| sed 's/.*\(mtu.*\)/\1/; s/.*\(txq.*\) (.*/\1/; s/ / = /' )
	echo "${val:0:-1}"
	;;
soundprofileset )
	values=${args[1]}
	if [[ $values == '18000000 60 1500 1000' || $values == '18000000 60' ]]; then
		rm -f /etc/soundprofile.conf
		soundprofile reset
	else
		val=( $values )
		echo -n "\
latency=${val[0]}
swappiness=${val[1]}
mtu=${val[2]}
txqueuelen=${val[3]}
" > /etc/soundprofile.conf
		soundprofile
	fi
	pushRefresh
	;;
statusonboard )
	ifconfig
	if systemctl -q is-active bluetooth; then
		echo '<hr>'
		bluetoothctl show | sed 's/^\(Controller.*\)/bluetooth: \1/'
	fi
	;;
timezone )
	timezone=${args[1]}
	timedatectl set-timezone $timezone
	pushRefresh
	;;
unmount )
	mountpoint=${args[1]}
	if [[ ${mountpoint:9:3} == NAS ]]; then
		umount -l "$mountpoint"
	else
		udevil umount -l "$mountpoint"
	fi
	pushRefresh
	;;
usbconnect )
	# for /etc/conf.d/devmon - devmon@http.service
	pushstream notify '{"title":"USB Drive","text":"Connected.","icon":"usbdrive"}'
	update
	;;
usbremove )
	# for /etc/conf.d/devmon - devmon@http.service
	pushstream notify '{"title":"USB Drive","text":"Removed.","icon":"usbdrive"}'
	update
	;;
wlandisable )
	if systemctl -q is-active hostapd; then
		/srv/http/bash/features.sh hostapddisable
	fi
	rmmod brcmfmac &> /dev/null
	pushRefresh
	;;
wlanset )
	rfkill | grep -q wlan || modprobe brcmfmac
	iw wlan0 set power_save off
	if [[ ${args[1]} == false ]]; then
		touch $dirsystem/wlannoap
	else
		rm -f $dirsystem/wlannoap
	fi
	pushRefresh
	;;
	
esac
