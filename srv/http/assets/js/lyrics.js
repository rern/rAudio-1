lyricsShow = function( data ) {
	if ( data !== 'current' ) {
		currentlyrics = data;
		var lyricshtml = data ? data.replace( /\n/g, '<br>' ) +'<br><br><br>·&emsp;·&emsp;·' : '<gr>(Lyrics not available.)</gr>';
		$( '#lyricstitle' ).text( lyricsTitle );
		$( '#lyricsartist' ).text( lyricsArtist );
		$( '#lyricstext' ).html( lyricshtml );
	}
	var bars = G.status ? G.bars : !$( '#bar-top' ).hasClass( 'hide' );
	$( '#lyrics' )
		.css( {
			  top    : ( bars ? '' : 0 )
			, height : ( bars ? '' : '100vh' )
		} )
		.removeClass( 'hide' );
	$( '#lyricstext' ).scrollTop( 0 );
	if ( bars ) $( '#bar-bottom' ).addClass( 'lyrics-bar-bottom' );
	bannerHide();
}
lyricsHide = function() {
	if ( $( '#artist' ).text() !== lyricsArtist || $( '#title' ).text() !== lyricsTitle ) {
		currentlyrics = '';
		lyricsArtist = '';
		lyricsTitle = '';
		$( '#lyricstext' ).empty();
		$( '#lyricstextarea' ).val( '' );
	}
	$( '#lyricsedit, #lyricstextoverlay' ).removeClass( 'hide' );
	$( '#lyricseditbtngroup' ).addClass( 'hide' );
	$( '#lyrics' ).addClass( 'hide' );
	if ( G.bars || !$( '#bar-top' ).hasClass( 'hide' ) ) $( '#bar-bottom' ).removeClass( 'lyrics-bar-bottom' );
}

var currentlyrics = '';
var lyricsArtist = '';
var lyricsTitle = '';
var lyricshtml = '';
$( '#lyricsartist' ).click( function() {
	getBio( $( this ).text() );
} );
$( '#title, #guide-lyrics' ).tap( function() {
	var artist = $( '#artist' ).text();
	var title = $( '#title' ).text();
	if ( !artist || !title ) return;
	
	if ( artist === $( '#lyricsartist' ).text() && title === $( '#lyricstitle' ).text() && currentlyrics ) {
		lyricsShow( 'current' );
		return
	}
	
	artist = artist.replace( /(["`])/g, '\\$1' ).replace( ' & ', ' and ' );
	title = title.replace( /(["`])/g, '\\$1' );
	file = G.status.player === 'mpd' ? '/mnt/MPD/'+ G.status.file : '';
	bash( [ 'lyrics', artist, title, 'local', file ], function( data ) {
		if ( data ) {
			lyricsTitle = title;
			lyricsArtist = artist;
			lyricsShow( data );
			return
		}
		
		var noparen = title.slice( -1 ) !== ')';
		var titlenoparen = title.replace( / $| \(.*$/, '' );
		info( {
			  icon        : 'lyrics'
			, title       : 'Bio / Lyrics'
			, width       : 500
			, textlabel   : [ '<i class="fa fa-artist wh"></i>', '<i class="fa fa-music wh"></i>' ]
			, values      : noparen ? [ artist, title ] : [ artist, titlenoparen ]
			, boxwidth    : 'max'
			, checkbox    : noparen ? '' : [ 'Title with parentheses content' ]
			, beforeshow  : noparen ? '' : function() {
				$( '#infoContent input' ).change( function() {
					$( '#infoContent input:text:eq( 1 )' ).val( $( this ).prop( 'checked' ) ? title : titlenoparen );
				} );
			}
			, buttonlabel : '<i class="fa fa-bio wh"></i>Bio'
			, button      : function() {
				if ( $( '#bio legend' ).text() != G.status.Artist ) {
					getBio( infoVal()[ 0 ] );
				} else {
					$( '#bar-top, #bar-bottom' ).addClass( 'hide' );
					$( '#bio' ).removeClass( 'hide' );
				}
			}
			, oklabel     : '<i class="fa fa-lyrics wh"></i>Lyrics'
			, ok          : function() {
				var values = infoVal();
				lyricsArtist = values[ 0 ];
				lyricsTitle = values[ 1 ];
				bash( [ 'lyrics', lyricsArtist, lyricsTitle ], function( data ) {
					lyricsShow( data );
				} );
				banner( 'Lyrics', 'Fetch ...', 'search blink', 20000 );
			}
		} );
	} );
} );
$( '#lyricstextarea' ).on( 'input', function() {
	$( '#lyricsundo, #lyricssave' ).removeClass( 'hide' );
	$( '#lyricsback' ).addClass( 'hide' );
} );
$( '#lyricsedit' ).click( function() {
	$( '#lyricseditbtngroup' ).removeClass( 'hide' );
	$( '#lyricsedit, #lyricstextoverlay' ).addClass( 'hide' );
	$( '#lyricstextarea' )
		.val( currentlyrics )
		.scrollTop( $( '#lyricstext' ).scrollTop() );
} );
$( '#lyricsclose' ).click( function() {
	if ( $( '#lyricstextarea' ).val() === currentlyrics || $( '#lyricstextarea' ).val() === '' ) {
		lyricsHide();
	} else {
		info( {
			  icon     : 'lyrics'
			, title    : 'Lyrics'
			, message  : 'Discard changes made to this lyrics?'
			, ok       : lyricsHide
		} );
	}
} );
$( '#lyricsback' ).click( function() {
	$( '#lyricseditbtngroup' ).addClass( 'hide' );
	$( '#lyricsedit, #lyricstextoverlay' ).removeClass( 'hide' );
} );
$( '#lyricsundo' ).click( function() {
	info( {
		  icon     : 'lyrics'
		, title    : 'Lyrics'
		, message  : 'Discard changes made to this lyrics?'
		, ok       : function() {
			$( '#lyricstextarea' ).val( currentlyrics );
			$( '#lyricsundo, #lyricssave' ).addClass( 'hide' );
			$( '#lyricsback' ).removeClass( 'hide' );
		}
	} );
} );
$( '#lyricssave' ).click( function() {
	if ( $( '#lyricstextarea' ).val() === currentlyrics ) return;
	
	info( {
		  icon     : 'lyrics'
		, title    : 'Lyrics'
		, message  : 'Save this lyrics?'
		, ok       : function() {
			var newlyrics = $( '#lyricstextarea' ).val();
			var artist = $( '#lyricsartist' ).text();
			var title = $( '#lyricstitle' ).text();
			bash( [ 'lyrics', artist, title, 'save', newlyrics.replace( /\n/g, '^' ) ] ); // keep lirics single line
			lyricstop = $( '#lyricstextarea' ).scrollTop();
			currentlyrics = newlyrics;
			lyricsShow( newlyrics );
			$( '#lyricseditbtngroup' ).addClass( 'hide' );
			$( '#lyricsedit, #lyricstextoverlay' ).removeClass( 'hide' );
		}
	} );
} );	
$( '#lyricsdelete' ).click( function() {
	info( {
		  icon    : 'lyrics'
		, title   : 'Lyrics'
		, message : 'Delete this lyrics?'
		, oklabel : '<i class="fa fa-minus-circle"></i>Delete'
		, okcolor : red
		, ok      : function() {
			var artist = $( '#lyricsartist' ).text();
			var title = $( '#lyricstitle' ).text();
			bash( [ 'lyrics', artist, title, 'delete' ] );
			currentlyrics = '';
			lyricsHide();
		}
	} );
} );
