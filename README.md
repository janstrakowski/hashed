This project is still being developed, even without the core features.
The "README" below is a faked proof-of-concept, meant only to show what I'm heading for approximately.

---

# About

*HashedBuild* helps you describe and instantiate Linux operating systems (and more) with code. It features:
 - output reproducibility (one specific input results in one specific output),
 - incremental updates (a small change should take shorter to build, a big change - longer),
 - standard compliance (what is used here is used also in many other projects),
 - an extensible design (anyone interested is able to write himself/herself any extra features),
 - a standard library (the most common operations are already bulit-in).

See also [NixOS](https://nixos.org/) and [Guix](https://guix.gnu.org/).
# Examples

## `XZ Utils 5.8.3`
```hashedbuild
gnulinux.containerbuild {
    archive = {
        downloadurl = "https://github.com/tukaani-project/xz/releases/download/v5.8.3/xz-5.8.3.tar.gz",
        sha256 = "CTtEvdGgLSf0FZ86UMI0jbd4rRzCPh9FFAdu8ix3Eyg=",
    },
    packages = { gnulinux.stdpkgs.{ autoconf, automake, gettext, libtool } },
    builder = gnulinux.configuremakeinstall {},
}
```

## "Hello, World!" on [Arduino](https://www.arduino.cc/)
```hashedbuild
let
    programtext = """
        void setup() {
          pinMode(LED_BUILTIN, OUTPUT);
        }

        void loop() {
          digitalWrite(LED_BUILTIN, HIGH);
          delay(1000);
          digitalWrite(LED_BUILTIN, LOW);
          delay(1000);
        }
    """
: arduino.deployment {
    inofiles = { fileFromText programtext },
}
```

# Donate
You can support me by a donation via: [a bank transfer](https://janstrakowski.github.io/jansdonations/) or [BuyMeACoffie](https://buymeacoffee.com/janstrakowski).
