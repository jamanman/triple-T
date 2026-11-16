# Triple-T

A slow-burn multiplayer battle on a 15×15 grid, for 4–20 players over 5 days. Built with React and Vite on Supabase: Postgres, Realtime, email auth and pg_cron.

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
| Player actions | RPCs: `act_move`, `act_shoot`, `act_add_heart`, `act_upgrade_range`, `gift` |
| Lobby | RPCs: `create_game`, `join_game`, `leave_game`, `start_game` |
| Jury / finale | RPCs: `cast_vote`, `submit_plea` |
| Live updates | Supabase Realtime `postgres_changes` → `src/lib/useGame.ts` |

- Every action locks the game row, so two simultaneous shots resolve one after the other, never both against stale data.
- **Hidden stats:** clients can't read the `players` table at all. They read `players_view`, which blanks other players' hearts, AP and range until the game is finished. Server error messages never reveal another player's stats either.
- **Private events:** buying a heart, upgrading range, looting AP from a kill and gifts are only shown to the players involved (the `visible_to` column on `events`, enforced by RLS). Public events like shots and kills give no numbers.
- AP drop times are stored in `ap_drops`, which players can't read, so drops are a surprise.
- Jury votes are secret: you can only read your own.

## Rule decisions

The rules leave some points open. This is how they are implemented; most are a one-line change in the migration.

- **Range is counted in up/down/left/right steps, never diagonally** (Manhattan distance), so it covers a diamond around you. With range 2 you can reach a player 2 squares straight up, or 1 across and 1 up, but not one 2 squares diagonally (that's 4 steps). Movement is likewise up, down, left or right only.
- **Days follow the host's chosen time zone.** Each day runs from midnight to midnight, and its two AP drops land at random times between 8am and 8pm. If the game starts after 8pm, day 1 is the next day.
- **Dead players get no AP drops.** They still occupy their square, so nobody can move onto it.
- **Gifts are free and private.** The hearts or AP you send are the cost, and only you and the receiver see the gift. You must keep at least 1 heart, AP can't be sent to the dead, and reviving takes exactly 1 heart. The 4-heart limit applies only to buying hearts: gifts can take someone above 4. A gift cap would let players discover someone's hearts by sending gifts and seeing which ones get refused.
- **Stats are secret.** You see only your own hearts, AP and range. Everyone sees positions, who is alive or dead, shots and kills (without numbers), revives and AP drops. All stats are revealed when the game ends.
- **Jury votes are daily.** The dead vote during the day and votes are tallied at midnight. The *haunted* player gets no AP drops the **next** day. The *bonus* player gets +2 AP straight away. Only votes from players who are still dead at the tally count. Ties are broken at random.
- **The finale starts** as soon as only 3 players are alive, or when day 5 ends. All actions freeze. Survivors write a plea, and the jury votes for a winner. The finale ends when every juror has voted, or after 24 hours.
- **A tied winner vote is a shared victory.** If the jury is empty or nobody voted, all survivors share the win.
- **Games need at least 4 players to start.** With 3 players or fewer, the finale would begin immediately. The host picks the maximum, from 4 to 20.

## Testing

`supabase/tests/game_test.sql` plays a full game as five users and checks 67 rules, including the RLS restrictions. It runs against a **throwaway** plain Postgres 15+ database, with stand-ins for Supabase's `auth` schema and roles:

```sh
PGHOST=localhost PGUSER=postgres PGDATABASE=scratch supabase/tests/run-local.sh
```
