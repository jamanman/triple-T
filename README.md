# Triple-T

A slow-burn multiplayer battle on a square grid, for 4–25 players, over as many days as the host chooses (or with no limit). Built with React and Vite on Supabase: Postgres, Realtime, email auth and pg_cron.

Players sign in with email and password, so they can resume a game from any device. Each player's hearts, AP and range are secret until the game ends.

All rules are enforced in the database. The browser can only read game state and call RPC functions, so players can't cheat by editing requests.

## Setup

1. **Create a Supabase project** at <https://supabase.com>.
2. **Apply the migrations** in `supabase/migrations/`, in order. Either:
   - paste each file into the dashboard's SQL Editor and run it, or
   - with the Supabase CLI: `supabase link --project-ref <ref>` then `supabase db push`.

   The second migration (`…000100_schedule_tick.sql`) enables **pg_cron** and schedules `internal.tick()` every minute. This runs AP drops, the midnight jury tally, day changes and the finale deadline. If the `create extension` line fails, enable pg_cron under *Database → Extensions* and run the file again.
3. **Set up email sign-in** (*Authentication*):
   - *Sign In / Providers → Email*: keep it enabled. Leave **Confirm email** on, so players must click a link before their first sign-in.
   - *URL Configuration*: set **Site URL** to where you host the game, and add `http://localhost:5173` to **Redirect URLs** for development. Confirmation and password-reset links return here.
   - *Emails → SMTP Settings*: Supabase's built-in mailer only sends a handful of emails per hour. For a real game with up to 20 people signing up, connect your own SMTP provider (Resend, Postmark, SES…).
   - If you turned on anonymous sign-ins for the earlier version, turn them off.
4. **Configure the frontend:**
   ```sh
   cp .env.example .env      # fill in the project URL and anon key (Settings → API)
   npm install
   npm run dev
   ```
5. **Deploy** by running `npm run build` and putting `dist/` on any static host (Vercel, Netlify, Cloudflare Pages…). Routing uses `#/…` hashes, so no rewrite rules are needed.

## How it works

| Piece | Where |
|---|---|
| Tables, RLS, rules, scheduler | `supabase/migrations/20261116000000_game_schema.sql` |
| Cron job | `supabase/migrations/20261116000100_schedule_tick.sql` |
| Hidden stats, cardinal range | `supabase/migrations/20261116000200_hidden_stats_cardinal_range.sql` |
| Activity feed, gift cap | `supabase/migrations/20261116000300_feed_and_gift_cap.sql` |
| Host settings | `supabase/migrations/20261117000000_lobby_settings.sql` |
| Gift and jury bonus notices | `supabase/migrations/20261117000100_gift_sender_bonus_notice.sql` |
| Game length, jury revotes | `supabase/migrations/20261117000200_game_length_and_revotes.sql` |
| Random daily tie-break | `supabase/migrations/20261117000300_daily_ties_random.sql` |
| Lobby settings | RPC: `update_settings` (host only, before the game starts) |
| Player actions | RPCs: `act_move`, `act_shoot`, `act_add_heart`, `act_upgrade_range`, `gift` |
| Lobby | RPCs: `create_game`, `join_game`, `leave_game`, `start_game` |
| Jury / finale | RPCs: `cast_vote`, `submit_plea` |
| Live updates | Supabase Realtime `postgres_changes` → `src/lib/useGame.ts` |

- Every action locks the game row, so two simultaneous shots resolve one after the other, never both against stale data.
- **Hidden stats:** clients can't read the `players` table at all. They read `players_view`, which blanks other players' hearts, AP and range until the game is finished. Server error messages never reveal another player's stats either.
- **Activity feed:** only AP handouts, moves, deaths and revives are posted, and the feed never says who shot, killed or revived whom. A player who is shot gets a private "You were shot!" notice. A gift receiver gets a private notice naming the sender, such as "Alice sent you 2 AP.". When the jury awards +2 AP, the winner sees "The jury awarded you 2 bonus AP." and everyone else sees "Someone received 2 bonus AP from the jury.". A haunting is told only to the haunted player. Nothing says who voted for what. Private entries use the `visible_to` column on `events`, enforced by RLS.
- **Refresh signals:** other changes that clients must notice (joins, pleas, new days) bump `games.updated_at`.
- AP drop times are stored in `ap_drops`, which players can't read, so drops are a surprise.
- Jury votes are secret: you can only read your own.

## Rule decisions

The rules leave some points open. This is how they are implemented; most are a one-line change in the migration.

- **Range is counted in up/down/left/right steps, never diagonally** (Manhattan distance), so it covers a diamond around you. With range 2 you can reach a player 2 squares straight up, or 1 across and 1 up, but not one 2 squares diagonally (that's 4 steps). Movement is likewise up, down, left or right only.
- **The host configures the game in the lobby.** Until the game starts, the host can set:

  | Setting | Range | Default |
  |---|---|---|
  | Grid size | 10×10 to 20×20 | 15×15 |
  | Max players | 4 to 25 (not below the number already joined) | 10 |
  | Max hearts | 1 to 10 | 4 |
  | AP drops per day | 1 to 12 | 2 |
  | AP window | any start and end time on the same day | 8am–8pm |
  | Time zone | any | the host's browser |
  | Game length | 1 to 365 days, or no limit | 5 days |

  Everyone else sees the saved settings update live. Players start with 3 hearts, or the max if it's lower.
- **Days follow the game's time zone.** Each day runs from midnight to midnight, and its AP drops land at random times inside the window. If the game starts after the window has closed for the day, day 1 is the next day. The window can't cross midnight.
- **Dead players get no AP drops.** They still occupy their square, so nobody can move onto it.
- **Gifts are free and private.** Only the receiver is told, and they're told who sent it. The hearts or AP you send are the cost. You must keep at least 1 heart, AP can't be sent to the dead, reviving takes exactly 1 heart, and gifts can't take anyone above the game's max hearts. (A refused heart gift does tell the giver the receiver is near the cap.)
- **Stats are secret.** You see only your own hearts, AP and range. Everyone sees positions, moves, who is alive or dead, revives and AP drops. All stats are revealed when the game ends.
- **Jury results are for the jury.** Only dead players can see who was haunted or got the bonus. The haunted player is told privately at each AP drop they miss. The bonus player is told privately, and everyone else is told that someone got the bonus, without saying who.
- **Jury votes are daily.** The dead vote during the day and votes are tallied at midnight. The *haunted* player gets no AP drops the **next** day. The *bonus* player gets +2 AP straight away. Only votes from players who are still dead at the tally count.
- **Daily ties are settled at random.** If the haunt or +2 AP vote is tied, one of the tied players is picked at random, straight away.
- **The finale starts** as soon as only 3 players are alive, or when the last day ends. With no day limit, only the 3-players rule applies. All actions freeze. Survivors write a plea, and the jury votes for a winner. The finale ends when every juror has voted, or after 24 hours.
- **A tied winner vote goes to a revote** between only the tied players. Everyone can see the revote. Each revote gets a fresh finale period, or ends once every juror has voted. Revotes repeat as long as they narrow the field. If a revote ends in exactly the same tie, or nobody votes in it, the tied players share the win. If the jury is empty or nobody voted at all, every survivor shares the win.
- **Games need at least 4 players to start.** With 3 players or fewer, the finale would begin immediately. The host picks the maximum, from 4 to 25.

## Testing

`supabase/tests/game_test.sql` plays a full game as five users, plus a second game to check the host settings, and checks 102 rules, including the RLS restrictions. It runs against a **throwaway** plain Postgres 15+ database, with stand-ins for Supabase's `auth` schema and roles:

```sh
PGHOST=localhost PGUSER=postgres PGDATABASE=scratch supabase/tests/run-local.sh
```
