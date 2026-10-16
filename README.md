# emaki-d

Official SDK for emaki (emaki.ai), the Japanese-language AI video generator for Seedance 2.5 and Seedance 2.0. Generate [Seedance 2.5](https://emaki.ai/seedance-2-5) and [Seedance 2.0](https://emaki.ai/seedance-2) clips, and images, from D with the API key of your [emaki](https://emaki.ai/?utm_source=dub&utm_medium=package) account.

```d
import emaki;

auto r = generateVideo("a paper lantern drifting down a night river, slow dolly-in");
if (r.ok) writeln(r.url); else writeln(r.reason, ": ", r.message);  // URL of the finished MP4
```

Each `generate` call submits the run, waits for it and returns the URL of the finished file. Every run costs credits on your emaki account, the same price as on the website.

## Install

```bash
dub add emaki
```

Uses `std.net.curl`, no other dependencies. The package also has a `cli` configuration (`dub build -c cli`) that builds an `emaki` command: `emaki "a prompt"` prints a clip URL, `emaki --image "a prompt"` an image URL, `emaki --credits` your remaining credits.

## API key

Sign up on [emaki.ai](https://emaki.ai/?utm_source=dub&utm_medium=package), create a key at [emaki.ai/settings/apikeys](https://emaki.ai/settings/apikeys), then pass it or export it:

```bash
export EMAKI_API_KEY=sk-...
```

A key runs on your account exactly like the site does: same models, same credits, and every run shows up in your library on emaki.ai.

## Video

The default model is `seedance_2_5` (5 seconds, 480p, 16:9, with sound). Parameters go in `Options.parameters` as a JSON object and are passed through as-is:

```d
import std.json : JSONValue;

// Seedance 2.5: 8 seconds, 720p, vertical
Options o;
o.parameters = JSONValue(["duration": JSONValue(8), "resolution": JSONValue("720p"), "aspect_ratio": JSONValue("9:16")]);
generateVideo("a street drummer in the rain, handheld", o);

// Seedance 2.0
Options o2 = { model: "seedance_2" };
generateVideo("a koi pond seen from above, petals falling", o2);
```

| model | what it is | main parameters |
|---|---|---|
| `seedance_2_5` | [Seedance 2.5](https://emaki.ai/seedance-2-5), the default | `duration` 4 to 30 · `resolution` 480p / 720p / 1080p · `aspect_ratio` 16:9, 4:3, 1:1, 3:4, 9:16, 21:9, adaptive · `generate_audio` · `image` · `last_frame_image` |
| `seedance_2` | [Seedance 2.0](https://emaki.ai/seedance-2) | `duration` 4 to 15 · `resolution` 480p / 720p / 1080p · `aspect_ratio` · `generate_audio` · `image` |
| `seedance_2_fast` | Seedance 2.0 Fast | `duration` 4 to 15 · `resolution` 480p / 720p · `aspect_ratio` · `image` |
| `seedance_2_mini` | Seedance 2.0 Mini, the cheapest video model | same as Fast |
| `minimax_h3` | MiniMax H3 | `duration` 5 to 15 · `aspect_ratio` · `image` |
| `veo_3_1` | Veo 3.1 | `resolution` 720p / 1080p / 4k · `aspectRatio` 16:9 / 9:16 · `image` |

### Image to video

Pass `image`, a public https URL, and it becomes the first frame; the prompt then describes the motion. This is the same [image to video](https://emaki.ai/image-to-video) flow as on the site:

```d
Options o;
o.parameters = JSONValue(["image": "https://example.com/statue.jpg"]);
generateVideo("the camera slowly orbits the statue", o);
```

On Seedance 2.5, `last_frame_image` pins the closing frame as well.

## Images

The default image model is `nano_banana_2_lite`, the cheapest run on the site:

```d
auto img = generateImage("a ramen stall in the rain, neon reflections");
Options o = { model: "nano_banana_2" };
o.parameters = JSONValue(["aspect_ratio": "16:9"]);
generateImage("a ukiyo-e style wave over a modern city", o);
```

Image models: `nano_banana_2_lite`, `nano_banana_2` (`resolution` 1K / 2K / 4K), `seedream_5_lite` (`quality` basic / high / ultra), `gpt_image_2` (`resolution` 1K / 2K / 4K). All take `aspect_ratio`.

## Submit now, collect later

```d
auto id = submit("a fox trotting through fresh snow", "seedance_2_5").url;
auto s = status(id);    // s.status: generating | completed | failed, s.videoUrl when completed
long left = credits();  // free to call
```

`Options` also takes `apiKey`, `timeoutSeconds` (default 900) and `pollMillis` (default 5000).

## Errors worth catching

Every call returns a `Result`; when `ok` is false, `reason` is one of:

- `Reason.auth`: no key, or the key is wrong or deleted (HTTP 401)
- `Reason.quota`: not enough credits left for this run (HTTP 402)
- `Reason.plan`: this model unlocks after the account has bought credits (HTTP 403)
- `Reason.busy`: another generation on this account is still in progress (HTTP 409)
- `Reason.rejected`: the content filter refused the prompt, or the account is cooling down after a refusal; reword rather than retry
- `Reason.validation`: a parameter is missing or out of range; the message says which
- `Reason.failed`: the run was accepted and then failed; the failure code says why
- `Reason.timeout`: the wait ran out; the run may still finish in your emaki library

Anything else (a network failure, a 5xx) comes back as `Reason.other` with the service's message.

## More on emaki

Clips you make here can be sharpened afterwards with the [AI video upscaler](https://emaki.ai/video-upscaler) on the site.

日本語での使い方は [シーダンス](https://emaki.ai/) へ。

MIT licensed. Made by [emaki](https://emaki.ai/?utm_source=dub&utm_medium=package).
