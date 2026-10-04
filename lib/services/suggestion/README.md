# Suggestion service

Songs in, suggested songs out. PulseIQ (`user_taste_service.dart`) only learns
and remembers the user's taste; everything about *finding* songs lives here.

```
  songs the user listened to ──►  SuggestionService  ──►  many playable songs
        (SeedSong, 1..5)               │
                                       ├─ MetaBrainzProvider   (priority 1)
                                       ├─ YoutubeProvider      (priority 2)
                                       └─ JioSaavnProvider     (priority 3)
                                                │
              MetaBrainz / YouTube candidates ──┴─► JioResolver ──► playable JioSaavn song
```

## How a request runs

1. Every provider is asked, in parallel, for songs similar to each seed. A
   provider never throws; "nothing" is an empty list.
2. MetaBrainz and YouTube candidates are **matched to JioSaavn** by
   `JioResolver`. A JioSaavn search result is accepted only if it agrees on
   title, at least one artist, the album (when both sides know it) and the
   length (±12 s, when both know it). No strict match means the suggestion is
   dropped, never "close enough".
3. Candidates are merged into distinct songs (`SongFingerprint`, so the same
   recording listed under two JioSaavn ids is one song). A song several sources
   agree on ranks higher, and so does one that fits several seeds.
4. The seeds, the excluded songs (queue, recent plays) and off-topic content
   (devotional / kids, unless the user listens to those) are removed.
5. Ordering: `tier + rank`. Tier scores are MetaBrainz 3, YouTube 2, JioSaavn 1,
   with the rank inside a tier adding less than the gap between tiers, so a
   higher-priority source always comes first unless sources agree. Agreement
   adds 0.5 per extra source and 0.6 per extra seed (capped at 1.0).
6. An optional `tasteBoost` (PulseIQ's `likeness`, scaled to at most 0.6)
   nudges the order inside that. Taste can reorder songs of the same source; it
   can never lift a song above a higher-priority source.
7. At most 4 songs per artist, unless there are so few artists that the cap
   could not fill the request (a rapper's catalogue).

## The slow source

ListenBrainz "similar recordings" takes **20 to 40 seconds** per song, and has
no data for many songs (especially recent or regional ones). So MetaBrainz is
fetched in the background: `SuggestionService.warmUp(seed)` is called when a
Stream song starts playing, the answer is cached, and `suggest` uses it if it is
ready (waiting at most 4 s for one that is still on its way). A song plays for
minutes, so the answer is usually there by the time the queue needs more songs.
MusicBrainz lookups are spaced at least 1.1 s apart, as it requires.

## Where it is used

* Autoplay (`PlayerBloc._streamAutoplaySongs`): seeds = the song the user
  picked + the song playing now.
* Radio (`PlayerBloc._onStartRadio`): the Radio flavour also adds the credited
  artists' other songs.
* Stream home (`StreamScreen._homeSuggestions`): several seeds from PulseIQ's
  `topSeedSongs`, favourites and recent plays.

The two services are registered in `injection_container.dart` and share one
`MetaBrainzProvider` and one `JioResolver`.

## Tests

`test/suggestion_service/` (title cleaning, matching rules, MetaBrainz parsing
and caching, mixing and ordering), `test/infinite_queue_test.dart` (the player
wiring), `test/user_taste_service_test.dart` (what PulseIQ answers).
