/**
 * Official D SDK for emaki (https://emaki.ai): generate Seedance 2.5 and
 * Seedance 2.0 clips, and images, with the API key of your emaki account.
 *
 * ---
 * import emaki;
 * auto r = generateVideo("a paper lantern drifting down a night river");
 * if (r.ok) writeln(r.url); else writeln(r.reason, ": ", r.message);
 * auto img = generateImage("a ramen stall in the rain, neon reflections");
 * ---
 *
 * Set `Options.apiKey` or EMAKI_API_KEY; create a key at
 * https://emaki.ai/settings/apikeys. Uses std.net.curl.
 */
module emaki;

import core.thread : Thread;
import core.time : msecs, seconds;
import std.algorithm : canFind;
import std.datetime.systime : Clock;
import std.json;
import std.net.curl : HTTP;
import std.process : environment;
import std.string : strip, toLower;

/// Why a call failed, in terms of what to do next.
enum Reason { none, auth, quota, plan, busy, rejected, validation, failed, timeout, other }

/// The outcome of a call: a URL or id in `url`, or why there is none.
struct Result { bool ok; string url; Reason reason; string message; int status; }

/// A run's record from `status`.
struct Status { bool ok; string id; string status; string videoUrl; string failureCode; Reason reason; string message; }

/// Call settings. `Options.init` is valid.
struct Options
{
    string model;               /// default seedance_2_5 (video) or nano_banana_2_lite (image)
    JSONValue parameters;       /// passed through: duration, resolution, aspect_ratio, image, ...
    string apiKey;              /// default EMAKI_API_KEY
    int pollMillis = 5000;
    int timeoutSeconds = 900;   /// video can queue
}

/// Service root, changeable for a test or a proxy.
__gshared string baseUrl = "https://emaki.ai";

/// The answer of one request: HTTP status and decoded body.
struct Reply { int status; JSONValue body; }

/// POST a JSON body. Replaceable in tests.
__gshared Reply delegate(string url, string body, string key) transport;

enum keysUrl = "https://emaki.ai/settings/apikeys";
enum defaultVideoModel = "seedance_2_5";
enum defaultImageModel = "nano_banana_2_lite";

shared static this()
{
    transport = (string url, string body, string key) {
        auto http = HTTP(url);
        http.method = HTTP.Method.post;
        http.addRequestHeader("Authorization", "Bearer " ~ key);
        http.addRequestHeader("Content-Type", "application/json");
        http.addRequestHeader("User-Agent", "emaki-d/0.1.0");
        http.postData = body;
        ubyte[] buf;
        http.onReceive = (ubyte[] d) { buf ~= d; return d.length; };
        http.perform();
        JSONValue parsed;
        try parsed = parseJSON(cast(string) buf.idup);
        catch (Exception) parsed = JSONValue.init;
        return Reply(http.statusLine.code, parsed);
    };
}

private bool has(const JSONValue v, string k)
{
    return v.type == JSONType.object && (k in v.object) !is null;
}

private string str(const JSONValue v, string k)
{
    return has(v, k) && v[k].type == JSONType.string ? v[k].str : "";
}

/// Map an HTTP status and error body to the reason that says what to do next.
Reason classify(int status, JSONValue body)
{
    auto code = str(body, "code");
    if (status == 401) return Reason.auth;
    if (status == 402) return Reason.quota;
    if (status == 403) return Reason.plan;
    if (status == 409) return Reason.busy;
    if (code == "content_cooldown" || code == "content_blocked") return Reason.rejected;
    if (status == 400) return Reason.validation;
    return Reason.other;
}

private Result fail(Reason r, string msg, int status = 0) { return Result(false, null, r, "emaki: " ~ msg, status); }

private Result call(string path, JSONValue body, string apiKey, out JSONValue answer)
{
    auto key = apiKey.length ? apiKey : environment.get("EMAKI_API_KEY", "");
    if (key.length == 0) return fail(Reason.auth, "an API key is required; create one at " ~ keysUrl);
    Reply r;
    try r = transport(baseUrl ~ path, body.toString, key);
    catch (Exception e) return fail(Reason.other, e.msg);
    if (r.status >= 200 && r.status < 300 && r.body.type == JSONType.object)
    {
        answer = r.body;
        return Result(true);
    }
    auto msg = str(r.body, "error");
    if (!msg.length) msg = str(r.body, "message");
    if (!msg.length) msg = "HTTP error";
    return fail(classify(r.status, r.body), msg, r.status);
}

/// Submit a run and return its id in `Result.url` without waiting.
Result submit(string prompt, string model, Options o = Options.init)
{
    if (prompt.strip.length == 0) return fail(Reason.validation, "prompt is required");
    JSONValue body = ["prompt": JSONValue(prompt), "model": JSONValue(model)];
    if (o.parameters.type == JSONType.object && o.parameters.object.length) body["parameters"] = o.parameters;
    JSONValue a;
    auto r = call("/api/video/ai", body, o.apiKey, a);
    if (!r.ok) return r;
    auto id = has(a, "data") ? str(a["data"], "id") : "";
    if (!id.length) return fail(Reason.other, "the service returned no id");
    return Result(true, id);
}

/// Look up a run: status is "generating", "completed" or "failed".
Status status(string id, string apiKey = null)
{
    JSONValue a;
    auto r = call("/api/video/status", JSONValue(["videoId": id]), apiKey, a);
    if (!r.ok) { Status s; s.reason = r.reason; s.message = r.message; return s; }
    auto d = has(a, "data") ? a["data"] : JSONValue.emptyObject;
    return Status(true, str(d, "id"), str(d, "status"), str(d, "videoUrl"), str(d, "failureCode"));
}

/// Remaining credits on the account (free to call). -1 with `reason` set on failure.
long credits(string apiKey = null, Reason* reason = null)
{
    JSONValue a;
    auto r = call("/api/user/get-user-credits", JSONValue.emptyObject, apiKey, a);
    Reason why = r.reason;
    if (r.ok)
    {
        // This endpoint answers refusals with HTTP 200 and code -1.
        if (has(a, "code") && a["code"].integer == 0 && has(a, "data") && has(a["data"], "remainingCredits"))
            return a["data"]["remainingCredits"].integer;
        why = str(a, "message").toLower.canFind("api key") ? Reason.auth : Reason.other;
    }
    if (reason) *reason = why;
    return -1;
}

/// Poll a submitted run until it completes, fails or the deadline passes.
Result wait(string id, Options o = Options.init)
{
    auto deadline = Clock.currTime + o.timeoutSeconds.seconds;
    while (Clock.currTime < deadline)
    {
        Thread.sleep(o.pollMillis.msecs);
        auto s = status(id, o.apiKey);
        if (!s.ok)
        {
            if (s.reason == Reason.auth) return Result(false, null, s.reason, s.message);
            continue; // a dropped poll is not a failed run
        }
        if (s.status == "completed" && s.videoUrl.length) return Result(true, s.videoUrl);
        if (s.status == "failed")
            return fail(Reason.failed, "the run failed (" ~ (s.failureCode.length ? s.failureCode : "unknown") ~ ")");
    }
    return fail(Reason.timeout, "deadline passed; the run may still finish in your emaki library");
}

/// Generate one clip and return its URL. Default model seedance_2_5.
Result generateVideo(string prompt, Options o = Options.init)
{
    auto r = submit(prompt, o.model.length ? o.model : defaultVideoModel, o);
    return r.ok ? wait(r.url, o) : r;
}

/// Generate one image and return its URL. Default model nano_banana_2_lite.
Result generateImage(string prompt, Options o = Options.init)
{
    auto r = submit(prompt, o.model.length ? o.model : defaultImageModel, o);
    return r.ok ? wait(r.url, o) : r;
}

unittest
{
    JSONValue[] bodies;
    string[] urls;
    Reply[] replies;
    auto saved = transport;
    scope (exit) transport = saved;
    transport = (string url, string body, string key) {
        urls ~= url;
        bodies ~= parseJSON(body);
        auto r = replies[0];
        replies = replies[1 .. $];
        return r;
    };
    Reply ok(string j) { return Reply(200, parseJSON(j)); }

    replies = [
        ok(`{"success":true,"data":{"id":"v1","status":"generating"}}`),
        ok(`{"success":true,"data":{"id":"v1","status":"generating"}}`),
        ok(`{"success":true,"data":{"id":"v1","status":"completed","videoUrl":"https://cdn.emaki.ai/v1.mp4"}}`),
    ];
    Options o = { apiKey: "sk-x", pollMillis: 0 };
    o.parameters = JSONValue(["duration": 6]);
    auto v = generateVideo("a fox", o);
    assert(v.ok && v.url == "https://cdn.emaki.ai/v1.mp4");
    assert(urls[0].canFind("/api/video/ai") && bodies[0]["model"].str == "seedance_2_5");
    assert(bodies[0]["parameters"]["duration"].integer == 6);
    assert(urls[1].canFind("/api/video/status") && bodies[1]["videoId"].str == "v1");

    bodies = null;
    replies = [
        ok(`{"success":true,"data":{"id":"i1","status":"generating"}}`),
        ok(`{"success":true,"data":{"id":"i1","status":"completed","videoUrl":"https://cdn.emaki.ai/i1.png"}}`),
    ];
    Options io = { apiKey: "sk-x", pollMillis: 0 };
    auto i = generateImage("a mug", io);
    assert(i.ok && i.url == "https://cdn.emaki.ai/i1.png");
    assert(bodies[0]["model"].str == "nano_banana_2_lite" && !has(bodies[0], "parameters"));

    replies = [
        ok(`{"success":true,"data":{"id":"f1","status":"generating"}}`),
        ok(`{"success":true,"data":{"id":"f1","status":"failed","failureCode":"provider_error"}}`),
    ];
    auto f = generateVideo("x", io);
    assert(!f.ok && f.reason == Reason.failed && f.message.canFind("provider_error"));

    struct Case { int status; string body; Reason want; }
    foreach (c; [
        Case(401, `{"error":"Invalid API key. Create one at https://emaki.ai/settings/apikeys"}`, Reason.auth),
        Case(402, `{"error":"Insufficient credits"}`, Reason.quota),
        Case(403, `{"error":"This model requires a purchase"}`, Reason.plan),
        Case(409, `{"error":"Video generation is already in progress"}`, Reason.busy),
        Case(429, `{"error":"cooling down","code":"content_cooldown"}`, Reason.rejected),
        Case(400, `{"error":"blocked","code":"content_blocked"}`, Reason.rejected),
        Case(400, `{"error":"Missing required parameters: prompt and model"}`, Reason.validation),
        Case(500, `{"error":"Internal error"}`, Reason.other),
    ])
    {
        replies = [Reply(c.status, parseJSON(c.body))];
        auto r = submit("x", "seedance_2_5", io);
        assert(!r.ok && r.reason == c.want && r.status == c.status);
    }

    replies = [ok(`{"code":0,"message":"ok","data":{"remainingCredits":42,"hasPurchasedCredits":false}}`)];
    assert(credits("sk-x") == 42);
    replies = [ok(`{"code":-1,"message":"Invalid API key. Create one at https://emaki.ai/settings/apikeys"}`)];
    Reason why;
    assert(credits("sk-x", &why) == -1 && why == Reason.auth);
}
