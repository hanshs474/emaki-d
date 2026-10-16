/// emaki "a prompt"           -> clip URL (Seedance 2.5)
/// emaki --image "a prompt"   -> image URL
/// emaki --credits            -> remaining credits      (set EMAKI_API_KEY)
import std.stdio;
import emaki;

int main(string[] args)
{
    if (args.length > 1 && args[1] == "--credits")
    {
        Reason why;
        auto n = credits(null, &why);
        if (n < 0) { stderr.writeln(why, ": could not read credits"); return why == Reason.auth ? 3 : 1; }
        writeln(n);
        return 0;
    }
    bool image = args.length > 1 && args[1] == "--image";
    auto rest = image ? args[2 .. $] : args[1 .. $];
    if (rest.length == 0) { stderr.writeln(`usage: emaki [--image] "prompt" | emaki --credits`); return 2; }
    auto r = image ? generateImage(rest[0]) : generateVideo(rest[0]);
    if (!r.ok) { stderr.writeln(r.reason, ": ", r.message); return r.reason == Reason.auth ? 3 : 1; }
    writeln(r.url);
    return 0;
}
