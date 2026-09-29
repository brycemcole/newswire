# Connecting your portfolio with Plaid

Newswire can show your brokerage positions (read-only) through [Plaid](https://plaid.com). It is bring-your-own-keys: **this repo contains no Plaid client ID, secret, or access token, and none is needed to build it.**

## Where credentials live

| Item | Stored | Sent to |
| --- | --- | --- |
| Plaid client ID, secret, environment | iCloud Keychain on your device (`com.brycecole.newswire.plaid`), entered in the app | Plaid only |
| Per-brokerage access tokens | Your device (created when you link an account) | Plaid only |
| Portfolio cache | App Support on your device | Nowhere |

The Newswire backend never sees Plaid credentials or holdings. Do not put Plaid keys in `wrangler.jsonc`, `.dev.vars`, CI secrets, or source; nothing reads them from there.

## Setup

1. **Create a Plaid account** at https://dashboard.plaid.com/signup and open **Developers → Keys**.
2. **Pick an environment.**
   - *Production*: real brokerages. The free Trial plan gives a small number of real Items; you may need to request Investments access for the "investments" product and complete Plaid's application questions.
   - *Sandbox*: fake data, good for trying the UI. Use the username `user_good` / password `pass_good` (`user_investments` if offered) in Link.
3. **Register the OAuth redirect URI** under **Developers → API → Allowed redirect URIs**. It must exactly match the value in `PlaidClient.redirectURI` (`ios/Sources/Plaid.swift`). Many brokerages (Fidelity, Schwab, and others) require OAuth, and Link fails without it.
4. **Add keys in the app**: Portfolio tab → *Add Plaid Keys* → paste the client ID and the secret for the environment you chose → Save.
5. **Link a brokerage**: Portfolio → *Connect account*, sign in through Plaid Link. Newswire requests only the `investments` product (positions and transaction history for cost-basis estimates).
6. Pull to refresh to sync. Use the same iCloud account on other devices and the keys follow.

## Running your own copy

The OAuth return path is tied to one deployment. If you are not building the original app, change these to your own values:

- `PlaidClient.redirectURI` in `ios/Sources/Plaid.swift` and the same URL in the Plaid dashboard.
- The `/.well-known/apple-app-site-association` response in `backend/src/index.ts`: replace `A792L5W262.com.brycecole.newswire` with `<YourTeamID>.<your bundle id>`. Set `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml` to match.
- Add the **Associated Domains** capability with `applinks:<your worker host>` so iOS hands the `/plaid/oauth` redirect back to the app. (`ios/Newswire.entitlements` does not currently declare it; add it if OAuth brokerages fail to return to the app.)
- Deploy the backend (`wrangler deploy` from `backend/`) so the redirect page and AASA file are served over HTTPS.

## Security notes

- Treat the Plaid secret like a password. If it leaks, rotate it in the Plaid dashboard and re-enter it in the app.
- Never commit keys. `.gitignore` already excludes `.env*`, `.dev.vars`, `.secrets/`, and signing files; keep it that way.
- To disconnect a brokerage, remove it in the Portfolio tab. This calls Plaid's `/item/remove` and revokes the access token.
- To check nothing slipped in: `git grep -nEi "(client_id|secret|access-(sandbox|production))[^a-z]"` should only match code that reads user-entered values.
