#SPDX-License-Identifier: AGPL-3.0-only
import std/[asyncdispatch, times, json, random, sequtils, strutils, tables, packedsets, os]
import types
import experimental/parser/session

# max requests at a time per session to avoid race conditions
const
  maxConcurrentReqs = 2
  hourInSeconds = 60 * 60
  apiMaxReqs: Table[Api, int] = {
    Api.search: 50,
    Api.tweetDetail: 500,
    Api.userTweets: 500,
    Api.userTweetsAndReplies: 500,
    Api.userMedia: 500,
    Api.userRestId: 500,
    Api.userScreenName: 500,
    Api.tweetResult: 500,
    Api.list: 500,
    Api.listTweets: 500,
    Api.listMembers: 500,
    Api.listBySlug: 500
  }.toTable

var
  sessionPool: seq[Session]
  enableLogging = false

template log(str: varargs[string, `$`]) =
  echo "[sessions] ", str.join("")

proc snowflakeToEpoch(flake: int64): int64 =
  int64(((flake shr 22) + 1288834974657) div 1000)

proc getSessionPoolHealth*(): JsonNode =
  let now = epochTime().int

  var
    totalReqs = 0
    limited: PackedSet[int64]
    reqsPerApi: Table[string, int]
    oldest = now.int64
    newest = 0'i64
    average = 0'i64

  for session in sessionPool:
    let created = snowflakeToEpoch(session.id)
    if created > newest:
      newest = created
    if created < oldest:
      oldest = created
    average += created

    if session.limited:
      limited.incl session.id

    for api in session.apis.keys:
      let
        apiStatus = session.apis[api]
        reqs = apiMaxReqs[api] - apiStatus.remaining

      # no requests made with this session and endpoint since the limit reset
      if apiStatus.reset < now:
        continue

      reqsPerApi.mgetOrPut($api, 0).inc reqs
      totalReqs.inc reqs

  if sessionPool.len > 0:
    average = average div sessionPool.len
  else:
    oldest = 0
    average = 0

  return %*{
    "sessions": %*{
      "total": sessionPool.len,
      "limited": limited.card,
      "oldest": $fromUnix(oldest),
      "newest": $fromUnix(newest),
      "average": $fromUnix(average)
    },
    "requests": %*{
      "total": totalReqs,
      "apis": reqsPerApi
    }
  }

proc getSessionPoolDebug*(): JsonNode =
  let now = epochTime().int
  var list = newJObject()

  for session in sessionPool:
    let sessionJson = %*{
      "apis": newJObject(),
      "pending": session.pending,
    }

    if session.limited:
      sessionJson["limited"] = %true

    for api in session.apis.keys:
      let
        apiStatus = session.apis[api]
        obj = %*{}

      if apiStatus.reset > now.int:
        obj["remaining"] = %apiStatus.remaining
        obj["reset"] = %apiStatus.reset

      if "remaining" notin obj:
        continue

      sessionJson{"apis", $api} = obj
      list[$session.id] = sessionJson

  return %list

proc rateLimitError*(): ref RateLimitError =
  newException(RateLimitError, "rate limited")

proc noSessionsError*(): ref NoSessionsError =
  newException(NoSessionsError, "no sessions available")

proc isLimited(session: Session; api: Api): bool =
  if session.isNil:
    return true

  if session.limited and api != Api.userTweets:
    if (epochTime().int - session.limitedAt) > hourInSeconds:
      session.limited = false
      log "resetting limit: ", session.id
      return false
    else:
      return true

  if api in session.apis:
    let limit = session.apis[api]
    return limit.remaining <= 10 and limit.reset > epochTime().int
  else:
    return false

proc isReady(session: Session; api: Api): bool =
  not (session.isNil or session.pending > maxConcurrentReqs or session.isLimited(api))

proc invalidate*(session: var Session) =
  if session.isNil: return
  log "invalidating: ", session.id

  # TODO: This isn't sufficient, but it works for now
  let idx = sessionPool.find(session)
  if idx > -1: sessionPool.delete(idx)
  session = nil

proc release*(session: Session) =
  if session.isNil: return
  dec session.pending

proc getSession*(api: Api): Future[Session] {.async.} =
  for i in 0 ..< sessionPool.len:
    if result.isReady(api): break
    result = sessionPool.sample()

  if not result.isNil and result.isReady(api):
    inc result.pending
  else:
    log "no sessions available for API: ", api
    raise noSessionsError()

proc setLimited*(session: Session; api: Api) =
  session.limited = true
  session.limitedAt = epochTime().int
  log "rate limited by api: ", api, ", reqs left: ", session.apis[api].remaining, ", id: ", session.id

proc setRateLimit*(session: Session; api: Api; remaining, reset: int) =
  # avoid undefined behavior in race conditions
  if api in session.apis:
    let limit = session.apis[api]
    if limit.reset >= reset and limit.remaining < remaining:
      return
    if limit.reset == reset and limit.remaining >= remaining:
      session.apis[api].remaining = remaining
      return

  session.apis[api] = RateLimit(remaining: remaining, reset: reset)

proc initSessionPool*(cfg: Config; path: string) =
  enableLogging = cfg.enableDebug

  if path.endsWith(".json"):
    log "ERROR: .json is not supported, the file must be a valid JSONL file ending in .jsonl"
    quit 1

  if not fileExists(path):
    log "ERROR: ", path, " not found. This file is required to authenticate API requests."
    quit 1

  log "parsing JSONL account sessions file: ", path
  for line in path.lines:
    sessionPool.add parseSession(line)

  log "successfully added ", sessionPool.len, " valid account sessions"
