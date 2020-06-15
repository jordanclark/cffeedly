component {
	// cfprocessingdirective( preserveCase=true );

	function init(
		string accessToken= ""
	,	string refreshToken= ""
	,	date authExpires= dateAdd( "d", 7, now() )
	,	string apiUrl= "https://cloud.feedly.com/v3"
	,	string userAgent= "CFML API Agent 0.1"
	,	numeric throttle= 100
	,	numeric httpTimeOut= 60
	,	boolean debug
	) {
		arguments.debug = ( arguments.debug ?: request.debug ?: false );
		structAppend( this, arguments, true );
		this.lastRequest= server.feedly_lastRequest ?: 0;
		return this;
	}

	function debugLog( required input ) {
		if( structKeyExists( request, "log" ) && isCustomFunction( request.log ) ) {
			if( isSimpleValue( arguments.input ) ) {
				request.log( "feedly: " & arguments.input );
			} else {
				request.log( "feedly: (complex type)" );
				request.log( arguments.input );
			}
		} else if( this.debug ) {
			var info= ( isSimpleValue( arguments.input ) ? arguments.input : serializeJson( arguments.input ) );
			cftrace(
				var= "info"
			,	category= "Feedly"
			,	type= "information"
			);
		}
		return;
	}

	function getWait() {
		var wait= 0;
		this.lastRequest= max( this.lastRequest, server.feedly_lastRequest ?: 0 );
		if( this.throttle > 0 || this.lastRequest > 0 ) {	
			wait= max( this.throttle - ( getTickCount() - this.lastRequest ), 0 );
		}
		return wait;
	}

	function setLastReq( numeric extra= 0 ) {
		if( this.throttle > 0 || arguments.extra > 0 ) {
			this.lastRequest= max( getTickCount(), server.feedly_lastRequest ?: 0 ) + arguments.extra;
			server.feedly_lastRequest= this.lastRequest;
		}
	}

	function getAuthToken() {
		if( !len( this.refreshToken ) ) {
			throw( message= "Unable to get a new access token without a refresh token.", type= "Custom.Feedly.CantRefresh" );
		}
		var out= this.apiRequest( api= "POST /auth/token", argumentCollection= {
			"refresh_token"= this.refreshToken
		,	"client_id"= "feedlydev"
		,	"client_secret"= "feedlydev"
		,	"grant_type"= "refresh_token"
		} );
		if( out.success && len( out.data.access_token ?: "" ) ) {
			this.accessToken= out.data.access_token;
			this.authExpires= dateAdd( "s", out.data.expires_in, now() );
			this.debugLog( "Got new accessToken: #this.accessToken#, expires in #out.data.expires_in# seconds" );
		} else {
			out.success= false;
			this.debugLog( "getAuthToken failed" );
			this.debugLog( out );
		}
		return out;
	}

	function getAuthenticated() {
		if( dateCompare( this.authExpires, now() ) != 1 || !len( this.accessToken ) ) {
			auth= this.getAuthToken();
			if( !auth.success ) { 
				return auth;
			}
		}
		return javaCast( "null", 0 ); // nullValue();
	}

	struct function apiRequest( required string api ) {
		var http= {};
		var item= "";
		var out= {
			"args"= arguments
		,	"success"= false
		,	"error"= ""
		,	"status"= ""
		,	"statusCode"= 0
		,	"response"= ""
		,	"verb"= listFirst( arguments.api, " " )
		,	"requestUrl"= this.apiUrl
		,	"data"= {}
		,	"delay"= 0
		};
		out.requestUrl &= listRest( out.args.api, " " );
		structDelete( out.args, "api" );
		// replace {var} in url 
		for( item in out.args ) {
			// strip NULL values 
			if( isNull( out.args[ item ] ) ) {
				structDelete( out.args, item );
			} else if( isSimpleValue( arguments[ item ] ) && arguments[ item ] == "null" ) {
				arguments[ item ]= javaCast( "null", 0 );
			} else if( findNoCase( "{#item#}", out.requestUrl ) ) {
				out.requestUrl= replaceNoCase( out.requestUrl, "{#item#}", urlEncodedFormat( out.args[ item ] ), "all" );
				structDelete( out.args, item );
			}
		}
		if( out.verb == "GET" ) {
			out.requestUrl &= this.structToQueryString( out.args, out.requestUrl, true );
		} else if( structKeyExists( out.args, "body" ) ) {
			out.body= serializeJSON( out.args.body, false, false );
		} else if( !structIsEmpty( out.args ) ) {
			out.body= serializeJSON( out.args, false, false );
		}
		this.debugLog( "API: #uCase( out.verb )#: #out.requestUrl#" );
		if( structKeyExists( out, "body" ) ) {
			this.debugLog( out.body );
		}
		// throttle requests to keep it from going too fast
		out.wait= this.getWait();
		if( out.wait > 0 ) {
			this.debugLog( "Pausing for #out.wait#/ms" );
			sleep( out.wait );
		}
		cftimer( type="debug", label="feedly request" ) {
			cfhttp( result="http", method=out.verb, url=out.requestUrl, charset="UTF-8", throwOnError=false, userAgent=this.userAgent, timeOut=this.httpTimeOut ) {
				if( out.verb == "POST" || out.verb == "PUT" || out.verb == "PATCH" ) {
					cfhttpparam( name= "content-type", type= "header", value= "application/json" );
				}
				if( len( this.accessToken ) ) {
					cfhttpparam( type= "header", name= "Authorization", value= "OAuth #this.accessToken#" );
				}
				if( structKeyExists( out, "body" ) ) {
					cfhttpparam( type= "body", value= out.body );
				}
			}
		}
		this.setLastReq();
		if( this.debug ) {
			out.http= http;
		}
		out.response= toString( http.fileContent );
		out.statusCode= http.responseHeader.Status_Code ?: 500;
		if( len( out.error ) ) {
			out.success= false;
		} else if( left( out.statusCode, 1 ) == 4 || left( out.statusCode, 1 ) == 5 ) {
			out.success= false;
			out.error= "status code error: #out.statusCode#";
		} else if( out.statusCode == "401" ) {
			out.error= "Error 401, unauthorized";
		} else if( out.statusCode == "429" ) {
			out.error= "Error 429, submitting requests too quickly";
			delay= ( structKeyExists( http.responseHeader, "Retry-After" ) ? http.responseHeader[ "Retry-After" ] * 1000 : this.throttle );
			this.setLastReq( delay );
		} else if( out.response == "Connection Timeout" || out.response == "Connection Failure" ) {
			out.error= out.response;
		} else if( left( out.statusCode, 1 ) == 2 ) {
			out.success= true;
		}
		// parse response 
		try {
			out.data= deserializeJSON( out.response );
			if( isStruct( out.data ) && structKeyExists( out.data, "errorMessage" ) ) {
				out.success= false;
				out.error= out.data.errorMessage;
			} else if( isStruct( out.data ) && structKeyExists( out.data, "status" ) && out.data.status == 400 ) {
				out.success= false;
				out.error= out.data.detail;
			}
		} catch (any cfcatch) {
			out.error= "JSON Error: " & (cfcatch.message?:"No catch message") & " " & (cfcatch.detail?:"No catch detail");
		}
		if( len( out.error ) ) {
			out.success= false;
		}
		this.debugLog( out.statusCode & " " & out.error );
		return out;
	}

	string function structToQueryString( required struct stInput, string sUrl= "", boolean bEncode= true ) {
		var sOutput= "";
		var sItem= "";
		var sValue= "";
		var amp= ( find( "?", arguments.sUrl ) ? "&" : "?" );
		for( sItem in stInput ) {
			sValue= stInput[ sItem ];
			if( !isNull( sValue ) && len( sValue ) ) {
				if( bEncode ) {
					sOutput &= amp & sItem & "=" & urlEncodedFormat( sValue );
				} else {
					sOutput &= amp & sItem & "=" & sValue;
				}
				amp= "&";
			}
		}
		return sOutput;
	}

	date function epochParse( required numeric date ) {
		return dateAdd( "l", arguments.date, dateConvert( "utc2Local", "January 1 1970 00:00" ) );
	}

	date function dateToEpoch( required date date ) {
		return dateDiff( "l", dateConvert( "utc2Local", "January 1 1970 00:00" ), arguments.date );
	}

	
	/**
	 * https://developer.feedly.com/v3/profile/
	 */
	struct function getProfile() {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /profile" );
	}

	/**
	 * https://developer.feedly.com/v3/collections/
	 */
	struct function getCollections( boolean withStats= false ) {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /collections", argumentCollection= arguments );
	}
	struct function getCollection( required string categoryId ) {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /collections/{categoryId}", argumentCollection= arguments );
	}
	struct function addFeedToCollection( required string categoryId, required string id, string title ) {
		return this.getAuthenticated() ?: this.apiRequest( api= "PUT /collections/{categoryId}/feeds", argumentCollection= arguments );
	}
	struct function removeFeedFromCollection( required string collectionId, required string feedId, boolean keepOrphanFeeds= false ) {
		return this.getAuthenticated() ?: this.apiRequest( api= "DELETE /collections/{collectionId}/feeds/{feedId}", argumentCollection= arguments );
	}

	/**
	 * https://developer.feedly.com/v3/enterprisecollections/#get-the-list-of-enterprise-collections-enterprise-only
	 */
	struct function getTeamCollections( boolean includedDeleted= false, boolean withStats= false ) {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /enterprise/collections", argumentCollection= arguments );
	}
	struct function getTeamCollection( required string categoryId ) {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /enterprise/collections/{categoryId}", argumentCollection= arguments );
	}
	

	/**
	 * https://developer.feedly.com/v3/categories/
	 */
	struct function getCategories( string sort= "" ) {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /categories" );
	}
	
	/**
	 * https://developer.feedly.com/v3/tags/
	 */
	struct function getTags( string sort= "" ) {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /tags" );
	}

	/**
	 * https://developer.feedly.com/v3/subscriptions/
	 */
	struct function getSubscriptions() {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /subscriptions" );
	}

	/**
	 * https://developer.feedly.com/v3/feeds/
	 */
	struct function getFeedMeta( required string feedId ) {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /feeds/{feedId}", argumentCollection= arguments );
	}
	
	struct function getFeedsMeta( required array feedIds ) {
		return this.getAuthenticated() ?: this.apiRequest( api= "POST /feeds/.mget", body= arguments.feedIds );
	}

	/**
	 * https://developer.feedly.com/v3/search/#find-feeds-based-on-title-url-or-topic
	 */
	struct function findFeeds(
		required string query
	,	numeric count= 20
	,	string locale
	) {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /search/feeds", argumentCollection= arguments );
	}

	/**
	 * https://developer.feedly.com/v3/entries/#get-the-content-of-an-entry
	 */
	struct function getEntry( required string entryId ) {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /entries/{entryId}", argumentCollection= arguments );
	}

	/**
	 * https://developer.feedly.com/v3/entries/#get-the-content-for-a-dynamic-list-of-entries
	 */
	struct function getEntries( required array entryIds ) {
		return this.getAuthenticated() ?: this.apiRequest( api= "POST /v3/entries/.mget", body= arguments.entryIds );
	}


	/**
	 * https://developer.feedly.com/v3/streams/
	 * 
	 * streams APIs are the core of the Feedly API. They return a list of entry ids or entry content for
	 * a single feed
	 * or a category (personal or team collection of feeds)
	 * or a tag (personal or team)
	 * or a global resource, e.g. all personal categories, all team tags, all annotated entries etc
	 */
	struct function getStream(
		required string streamId
	,	numeric count= 20
	,	string ranked= "newest" // oldest, engagement
	,	boolean unreadOnly= false
	,	string newerThan= ""
	,	string continuation
	,	boolean showMuted= false
	,	boolean importantOnly= false
	) {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /streams/contents", argumentCollection= arguments );
	}

	/**
	 * https://developer.feedly.com/v3/streams/#get-a-list-of-entry-ids-for-a-specific-stream
	 * 
	 * Get a list of entry ids for a specific stream
	 */
	struct function getStreamIDs(
		required string streamId
	,	numeric count= 20
	,	string ranked= "newest" // oldest, engagement
	,	boolean unreadOnly= false
	,	numeric newerThan
	,	string continuation
	) {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /streams/ids", argumentCollection= arguments );
	}
	
	/**
	 * https://developer.feedly.com/v3/mixes/
	 * 
	 * This API allows application to get access to the most engaging content available in a stream. The stream can be a feed, a category, or a topic.
	 */
	struct function getMixes(
		required string streamId
	,	numeric count= 3
	,	boolean unreadOnly= false
	,	numeric hours
	,	numeric newerThan
	,	boolean backfill= false
	,	string locale
	) {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /mixes/{streamId}/contents", argumentCollection= arguments );
	}

	/**
	 * https://developer.feedly.com/v3/search/#search-the-content-of-a-stream
	 * 
	 * Search the content of a stream
	 */
	struct function searchStream(
		required array streamId
	,	required string query
	,	numeric count= 10
	,	numeric newerThan
	,	boolean unreadOnly= false
	,	string continuation
	,	string fields= "all" /* all, title, author, keywords */
	,	string embedded= "" /* audio, video, doc or any */
	,	string engagement
	,	string locale
	) {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /search/contents", argumentCollection= arguments );
	}

	/**
	 * https://developer.feedly.com/v3/markers/#get-the-list-of-unread-counts
	 */
	struct function getMarkers() {
		return this.getAuthenticated() ?: this.apiRequest( api= "GET /markers/counts" );

	}

	/**
	 * https://developer.feedly.com/v3/markers/#mark-a-feed-as-read
	 */
	struct function markFeedRead( required feedIds, required string last ) {
		if( isSimpleValue( arguments.feedIds ) ) {
			arguments.feedIds= listToArray( arguments.feedIds, "|" );
		}
		var body = {
			"action"= "markAsRead"
		,	"type"= "feeds"
		,	"feedIds"= arguments.feedIds
		};
		if( isNumeric( arguments.last ) ) {
			body[ "asOf" ]= arguments.last;
		} else {
			body[ "lastReadEntryId" ]= arguments.last;
		}
		return this.getAuthenticated() ?: this.apiRequest( api= "POST /markers", body= body );
	}

	/**
	 * https://developer.feedly.com/v3/markers/#mark-a-category-as-read
	 */
	struct function markCategoryRead( required categoryIds, required string last ) {
		if( isSimpleValue( arguments.categoryIds ) ) {
			arguments.categoryIds= listToArray( arguments.categoryIds, "|" );
		}
		var body = {
			"action"= "markAsRead"
		,	"type"= "categories"
		,	"categoryIds"= arguments.categoryIds
		};
		if( isNumeric( arguments.last ) ) {
			body[ "asOf" ]= arguments.last;
		} else {
			body[ "lastReadEntryId" ]= arguments.last;
		}
		return this.getAuthenticated() ?: this.apiRequest( api= "POST /markers", body= body );
	}

	/**
	 * https://developer.feedly.com/v3/markers/#mark-a-category-as-read
	 */
	struct function markTagRead( required tagIds, required string last ) {
		if( isSimpleValue( arguments.tagIds ) ) {
			arguments.tagIds= listToArray( arguments.tagIds, "|" );
		}
		var body = {
			"action"= "markAsRead"
		,	"type"= "tags"
		,	"tagIds"= arguments.tagIds
		};
		if( isNumeric( arguments.last ) ) {
			body[ "asOf" ]= arguments.last;
		} else {
			body[ "lastReadEntryId" ]= arguments.last;
		}
		return this.getAuthenticated() ?: this.apiRequest( api= "POST /markers", body= body );
	}

	/**
	 * https://developer.feedly.com/v3/markers/#mark-one-or-multiple-articles-as-read
	 */
	struct function markAsRead( required entryIds ) {
		if( isSimpleValue( arguments.entryIds ) ) {
			arguments.entryIds= listToArray( arguments.entryIds, "|" );
		}
		var body = {
			"action"= "markAsRead"
		,	"type"= "entries"
		,	"entryIds"= arguments.entryIds
		};
		return this.getAuthenticated() ?: this.apiRequest( api= "POST /markers", body= body );
	}

	/**
	 * https://developer.feedly.com/v3/markers/#mark-one-or-multiple-articles-as-read
	 */
	struct function keepUnread( required entryIds ) {
		if( isSimpleValue( arguments.entryIds ) ) {
			arguments.entryIds= listToArray( arguments.entryIds, "|" );
		}
		var body = {
			"action"= "keepUnread"
		,	"type"= "entries"
		,	"entryIds"= arguments.entryIds
		};
		return this.getAuthenticated() ?: this.apiRequest( api= "POST /markers", body= body );
	}
	
	/**
	 * https://developer.feedly.com/v3/markers/#mark-one-or-multiple-articles-as-saved
	 */
	struct function markAsSaved( required entryIds ) {
		if( isSimpleValue( arguments.entryIds ) ) {
			arguments.entryIds= listToArray( arguments.entryIds, "|" );
		}
		var body = {
			"action"= "markAsSaved"
		,	"type"= "entries"
		,	"entryIds"= arguments.entryIds
		};
		return this.getAuthenticated() ?: this.apiRequest( api= "POST /markers", body= body );
	}

	/**
	 * https://developer.feedly.com/v3/markers/#mark-one-or-multiple-articles-as-unsaved
	 */
	struct function markAsUnsaved( required entryIds ) {
		if( isSimpleValue( arguments.entryIds ) ) {
			arguments.entryIds= listToArray( arguments.entryIds, "|" );
		}
		var body = {
			"action"= "markAsUnsaved"
		,	"type"= "entries"
		,	"entryIds"= arguments.entryIds
		};
		return this.getAuthenticated() ?: this.apiRequest( api= "POST /markers", body= body );
	}


}
