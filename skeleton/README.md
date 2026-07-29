# The pinned Flarum skeleton

`composer.json` + `composer.lock` describing exactly which Flarum this image
installs. **The lock is the pin.** The constraints in `composer.json` are loose
(`*` on the bundled extensions — that is Flarum's own skeleton style), but
`composer install` from a committed lock installs the exact versions recorded in
it and ignores the constraints entirely.

These files are not this repository's own manifest. Nothing here is a PHP
project; they describe the forum the image builds.

## Why this exists

The image used to resolve Flarum from Packagist when a container first started —
`^2.0` at beta stability, plus six extensions at bare `*`. Seven floating
constraints meant the same image tag could produce different forums a week
apart, a first boot required working network access, and an image tag could not
say which Flarum it contained. See issue #2.

## Current pin

Flarum `v2.0.0-rc.5`, 193 packages.

Note there is **no stable Flarum 2.0 yet**, so `minimum-stability: beta` is
currently required rather than a shortcut. When 2.0 goes stable, re-resolve and
this can tighten.

## Regenerating

Do not resolve this by hand, and do not resolve it on a laptop. It needs PHP 8.3
with the exact extension set the image ships — resolve somewhere missing `intl`
or `exif` and Composer will pick versions production cannot run.

Run **Actions → Resolve skeleton lock**, giving the Flarum version you want.
Download the `skeleton-lock` artifact and commit the two files here. The
workflow audits what it resolved and fails on any advisory, so a bump that would
pin a known-vulnerable package cannot land quietly.

That is the whole update path: moving Flarum is a reviewable diff in a pull
request, instead of something that happens silently the next time a container
boots.
