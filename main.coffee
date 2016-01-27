Crawler     = require('simplecrawler')
urlparse    = require('url')
request     = require('request')
async       = require 'async'
fs          = require 'fs'
express     = require 'express'
cheerio     = require 'cheerio'
util        = require 'util'
soap        = require 'soap'

bricksetConfig = {}
    
###
# 
###
callBricksetApi = (apiFunction, args, done) ->
    async.waterfall [
        # create soap client
        (cb) =>
            if bricksetConfig.bricksetClient isnt undefined
                return cb null, bricksetConfig.bricksetClient
            soap.createClient bricksetConfig.api_url , (err, client) =>
                return cb err   if err  
                bricksetConfig.bricksetClient = client
                cb null, client
        ,
        # login if no user hash already stored
        (client, cb) =>
            if bricksetConfig.userHash
                return cb null, client
            loginArgs = 
                apiKey : bricksetConfig.api_key
                username: bricksetConfig.username
                password: bricksetConfig.password
            
            client.login loginArgs, (error, result) =>
                bricksetConfig.userHash = result.loginResult
                cb null, client
        ,
        # call soap function
        (client, cb) => 
            # prepare function args
            args.apiKey = bricksetConfig.api_key
            args.userHash = bricksetConfig.userHash
            console.log args
            client[apiFunction] args, (err, result) =>
                return cb err   if err
                return cb null, result
    ], done
        

###
# Retrieve the content of a given url. Implemented using simplecrawler
###
retrieveContent = (url, cb) ->
    if !url
        return cb 'Empty Url', undefined
    if (typeof url) isnt 'string'
        return cb 'Invalid Url', undefined

    # map containing url : content of the page
    pageContent = undefined
    pageError = undefined
    
    # split url in domain and path
    {protocol, hostname, path}  = urlparse.parse url 
    cw = new Crawler hostname

    cw.path = path
    cw.initialPath = cw.path
    cw.maxDepth = 0
    cw.initialProtocol =  'http'
    cw.maxConcurrency = 1
    cw.userAgent = 'Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)'

    pagesFetching = []
    # add condition for urls to be followed and fetched
    cw.addFetchCondition (urlToFetch) ->
        return urlToFetch is url

    cw.on 'fetchcomplete', (queueItem, responseBuffer, response) =>
        {path} = urlparse.parse queueItem.url
        console.log '[DEBUG] completed ' + queueItem.url
        pageContent = responseBuffer.toString 'UTF8'
        
    cw.on 'fetcherror', (queueItem, response) ->
        pageError = response

    cw.on 'complete', () =>
        console.log 'Crawler completed'
        cb pageError, pageContent

    cw.start()

BASE_URL = 'http://www.brickpicker.com/bpms/set.cfm?set='

###
# Retrieve the item data given a lego item id. Data and prices are retrieved from brickpicker
###
getItemPricing = (itemId) ->
    (done) =>
        async.waterfall [
            (cb) => 
                # retrieve brickpicker page
                # fs.readFile './tmp.html' , cb
                retrieveContent BASE_URL + itemId  , cb
            ,
            (page, cb) =>
                # define css selectors
                patterns = 
                    name    : '.bottom-twenty h1' 
                    themes  : '.bottom-twenty a' # from thrid to last-1
                    currentPrice    : '.table-responsive tr td:contains("€")'
                    retailPrice     : '.retail-price ul li:contains("ITA")'
                    year    : '.product-detail ul li:contains("year")'
                
                # extract item data and price
                dom = cheerio.load page
                item = 
                    # name            : dom(patterns.name).text()
                    currentPrice    : ((dom(patterns.currentPrice).text().split '€')[1] || '').split('(')[0].trim()
                    currentPriceUsed: ((dom(patterns.currentPrice).text().split '€')[2] || '').split('(')[0].trim()
                    retailPrice     : ((dom(patterns.retailPrice).text().split '€')[1] || '').trim()
                    # year            : dom(patterns.year).text().split(':')[1].trim()
                    # themes          : []
                # extract themes
                # for index, obj of dom(patterns.themes)
                #     if !isNaN(parseInt index) and ((parseInt index)  > 1)
                #         item.themes.push obj.children[0].data
                # # (remove last theme, is title)
                # item.themes = item.themes[..-2]
                cb null, item
        ], (error, item) =>
            done error, item
###
# Search for sets given a set of parameter (year, theme, query...)
# !!! Not working currently because of server side bug
# Plus checks the current pricing on brickpicker
###    
getSets = (query, done) ->
    callBricksetApi 'getSets' , query, (err, result) =>
        return done err     if err
        
        priceFns = {}
        sets = {}
        for set in result
            sets[set.setID] = set
            priceFns[set.setID] = getItemPricing set.setID   
        async.series priceFns, (error, results) =>
            for setId, pricing of results
                sets[setId].pricing = pricing
            return done error, sets
        

###
# Returns a set given its number
###
getSet = (setNumber, done) ->
    callBricksetApi 'getSet' , {SetID : setNumber}, (err, result) ->
        return done err     if err or !result
        set = if result then result.getSetResult.sets[0] else {}
        
        set_number = set.number
        set_number += '-' + set.numberVariant if set.numberVariant
        
        (getItemPricing set_number) (error, pricing) ->
            set.pricing = pricing
            done null, set

setupServer = () ->
    server = new express()
    
    # load external config
    config = require __dirname + '/config'
    bricksetConfig = config.brickset
    
    server.get '/item/:itemId' , (req, res) =>
        getItem req.params.itemId , (error, result) ->
            return res.status(500).send(error)  if error
            res.status(200).send(result)

    server.get '/set/:setnr' , (req, res) =>
        getSet req.params.setnr , (error, result) ->
            return res.status(500).send(error)  if error
            res.status(200).send(result)
    
    server.get '/sets' , (req, res) =>
        getSets req.query , (error, result) ->
            return res.status(500).send(error)  if error
            res.status(200).send(result)

    server.listen 3000, () ->
    console.log 'Example app listening on port 3000!' 
    
    
setupServer()