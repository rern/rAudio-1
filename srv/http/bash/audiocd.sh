#!/bin/bash

dirtmp=/srv/http/data/shm
diraudiocd=/srv/http/data/audiocd

pushstream() {
	curl -s -X POST http://127.0.0.1/pub?id=$1 -d "$2"
}
pushstreamNotify() { # double quote "$1" needed
	if [[ -n $2 ]]; then
		pushstream notify '{"title":"Audio CD","text":"'"$1"'","icon":"audiocd blink","delay":-1}'
	else
		pushstream notify '{"title":"Audio CD","text":"'"$1"'","icon":"audiocd"}'
	fi
}
pushstreamPlaylist() {
	pushstream playlist "$( php /srv/http/mpdplaylist.php current )"
}

[[ -n $1 ]] && pushstreamNotify "USB CD $1"

if [[ $1 == on ]]; then
	sed -i '/^decoder/ i\
input { #cdio0\
	plugin         "cdio_paranoia"\
	speed          "12" \
} \
' /etc/mpd.conf
	systemctl restart mpd
	pushstream refresh '{ "page": "player" }'
	exit
elif [[ $1 == eject || $1 == off ]]; then # eject/off : remove tracks from playlist
	rm -f $dirtmp/audiocd
	tracks=$( mpc -f %file%^%position% playlist | grep ^cdda: | cut -d^ -f2 )
	if [[ -n $tracks ]]; then
		pushstreamNotify 'Removed from Playlist.'
		[[ $( mpc | head -c 4 ) == cdda ]] && mpc stop
		tracktop=$( echo "$tracks" | head -1 )
		mpc del $tracks
		if (( $tracktop > 1 )); then
			mpc play $(( tracktop - 1 ))
			mpc stop
		fi
		pushstreamPlaylist
	fi
	if [[ $1 == off ]]; then
		sed -i '/#cdio/,/^$/ d' /etc/mpd.conf
		systemctl restart mpd
		pushstream refresh '{ "page": "player" }'
	fi
	exit
fi

[[ -n $( mpc -f %file% playlist | grep ^cdda: ) ]] && exit

cddiscid=( $( cd-discid 2> /dev/null ) ) # ( id tracks leadinframe frame1 frame2 ... totalseconds )
[[ -z $cddiscid ]] && exit

discid=${cddiscid[0]}

if [[ ! -e $diraudiocd/$discid ]]; then
	pushstreamNotify 'Search CD data ...' -1
	server='http://gnudb.gnudb.org/~cddb/cddb.cgi?cmd=cddb'
	discdata=$( echo ${cddiscid[@]} | tr ' ' + )
	options='hello=owner+rAudio+rAudio+1&proto=6'
	query=$( curl -sL "$server+query+$discdata&$options" | head -2 | tr -d '\r' )
	code=$( echo "$query" | head -c 3 )
	if (( $code == 210 )); then  # exact match
	  genre_id=$( echo "$query" | sed -n 2p | cut -d' ' -f1,2 | tr ' ' + )
	elif (( $code == 200 )); then
	  genre_id=$( echo "$query" | cut -d' ' -f2,3 | tr ' ' + )
	fi
	if [[ -n $genre_id ]]; then
		pushstreamNotify 'Fetch CD data ...' -1
		data=$( curl -sL "$server+read+$genre_id&$options" | grep '^.TITLE' | tr -d '\r' ) # contains \r
		readarray -t artist_album <<< $( echo "$data" | grep '^DTITLE' | sed 's/^DTITLE=//; s| / |\n|' )
		artist=${artist_album[0]}
		album=${artist_album[1]}
		readarray -t titles <<< $( echo "$data" | tail -n +1 | cut -d= -f2 )
	fi
	frames=( ${cddiscid[@]:2} )
	unset 'frames[-1]'
	frames+=( $(( ${cddiscid[@]: -1} * 75 )) )
	framesL=${#frames[@]}
	for (( i=1; i < framesL; i++ )); do
		f0=${frames[$(( i - 1 ))]}
		f1=${frames[i]}
		time=$(( ( f1 - f0 ) / 75 ))$'\n'  # 75 frames/sec
		tracks+="$artist^$album^${titles[i]}^$time"
	done
	echo "$tracks" > $diraudiocd/$discid
fi
# suppress getPlaybackStatus in passive.js
if [[ -e /srv/http/data/system/autoplaycd ]]; then
	autoplaycd=1
	pushstream playlist '{"autoplaycd":1}'
fi
# add tracks to playlist
pushstreamNotify 'Add tracks to Playlist ...'
trackL=${cddiscid[1]}
for i in $( seq 1 $trackL ); do
  mpc add cdda:///$i
done
echo $discid > $dirtmp/audiocd
pushstreamPlaylist

if [[ -n $autoplaycd ]]; then
	cdtrack1=$(( $( mpc playlist | wc -l ) - $trackL + 1 ))
	/srv/http/bash/cmd.sh "mpcplayback
play
$cdtrack1"
fi

# coverart
if [[ -z $artist || -z $album ]]; then
	artist_album=$( head -1 $diraudiocd/$discid )
	artist=$( echo $artist_album | cut -d^ -f1 )
	album=$( echo $artist_album | cut -d^ -f2 )
fi
[[ -z $artist || -z $album ]] && exit

args="\
$artist
$album
audiocd
$discid"
/srv/http/bash/status-coverartonline.sh "$args" &> /dev/null &
