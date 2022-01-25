amqp = require 'amqp-as-promised'
genrun = require 'q-genrun'
assert = require 'assert'

gcm = require './services/gcm'
apn = require './services/apn'
esclient = require './db/esclient'
db = require './db'

if global.gc then setInterval((-> global.gc()), 5000)

conf =
  connection:
    url: process.env.RABBITMQ_URL or "amqp://localhost:5672//?heartbeat=10"
  logLevel: 'warn'
  rpc: timeout: 5000

amqpc = amqp(conf)


serviceForType = (type) -> if type is 'gcm' then gcm else apn


send = (msg) -> genrun ->

  # As a reference
  exampleMessage =
    tokens: ["1", "2"]
    type: "apn" # or "gcm"
    notification:
      badge: 0
      message: "Some message"
      payload: { some: "data" } # <- not mandatory

  try
    # a bit of validation
    assert(
      msg.tokens,
      'Notification has no destinations (tokens)'
    )
    assert(
      msg.notification.badge or msg.notification.message or msg.notification.alert,
      'Notification is empty (no alert, message, badge)'
    )
    assert(
      msg.type in ['apn', 'gcm'],
      "Notification type unknown (#{msg.type} is not [apn|gcm])"
    )
    service = serviceForType(msg.type)
    result = yield service.send(msg.notification, msg.tokens)
    return result

  catch error # log and re-throw the error back to the amqp producer
    console.log 'PushNotification service error', error
    console.log error.stack.split('\n') if error.stack
    throw error


apn.setInvalidTokenCallback(db.deleteById)
gcm.setInvalidTokenCallback(db.deleteById)

module.exports.start = start = -> genrun ->

  options = { ack: true, prefetchCount: 1 }

  serve = (name, fn) -> genrun ->
    yield amqpc.serve 'myexchange', "push-notification-service.#{name}", options, (msg, headers, del) -> genrun ->
      try
        yield fn(msg...) # msg is an array of arguments for the fn
      catch e
        console.log(e, e.stack?.split('\n')) # log the error locally
        throw e # ...and let amqpc propagate the error to the caller

  # expose function to send push notifications
  yield serve('send', send)

  # expose functions to manage push tokens (db)
  for name, fn of db when typeof(fn) is 'function'
    # console.log "Binding db.#{name} to AMQP queue push-notification-service.#{name}"
    yield serve(name, fn)

  yield esclient.waitES()
  yield esclient.indexTemplatesInit()

  # possibly handle graceful shutdown of the service
  gracefulShutdown = (opts) ->
    console.log 'PushNotification service shutting down'
    amqpc.shutdown().then ->
      process.exit 0
    setTimeout -> # if not connected amqpc hangs.shutdown indefinitely, so..
      process.exit 0
    , 2000

  process.on 'SIGINT', gracefulShutdown
  process.on 'SIGTERM', gracefulShutdown


if not module.parent then start()
