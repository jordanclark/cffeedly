```
         __   __                  _  _        
   ___  / _| / _|  ___   ___   __| || | _   _ 
  / __|| |_ | |_  / _ \ / _ \ / _` || || | | |
 | (__ |  _||  _||  __/|  __/| (_| || || |_| |
  \___||_|  |_|   \___| \___| \__,_||_| \__, |
                                        |___/ 
```
# cffeedly
feedly.com ColdFusion Rest API Client. This client only supports developer access tokens, not full oauth.
So this is useful for accessing your own feeds, but isn't yet able to support 3rd party client accounts. 

To get started, sign up for a feedly.com account, then request a developer access token here:
https://feedly.com/v3/auth/dev

This will give you a 7 day access token, if you have a paid account it will also give you a refresh token which
can be used to regenerate a new access token.

Feedly represents dates as numbers, use the included epochParse() to convert these to date objects.

## Getting Started
```
feedly = new cffeedly.feedly( refreshToken= "..." );
articles= feedly.getStream( "feed/http://feeds.engadget.com/weblogsinc/engadget" );
if( articles.success ) { 
	dump( articles.data.items );
}
```

## Dev Documentation
https://developer.feedly.com/v3/developer/

## To Install
Run the following from commandbox:
`box install cffeedly`

## Changes
2020-04-07 Open source release

