# Principles

What quotabot is, what it refuses to be, and how to check that for yourself
rather than taking it on faith.

This is not a mission statement. Every promise below is either enforced by a
release gate or verifiable with a command on your own machine, and each one says
how.

## The deal

- No account. Nothing to sign up for, nothing to log in to, no profile.
- No subscription, no tiers, no paid unlock. Apache 2.0, all of it.
- No telemetry. Not opt-out, not opt-in, none at all.
- No advertising, no upsell, no nag screens.
- No inference. quotabot is a tool for people who use AI that itself makes no
  model call and reads no prompt, code, or model output.
- No lock-in. If this project stopped tomorrow, your installed copy keeps
  working, because nothing it needs runs on our machines. There are none.

## Why these, specifically

These are not arbitrary. They are the specific things people say they are tired
of, and a quota meter is exactly the kind of small tool that gets ruined by each
one.

**Recurring fees for static value.** Research on subscription fatigue finds
households paying roughly $273 a month across services and underestimating that
total, and that even a $1.99 monthly fee is a real barrier for most shoppers.
The finding that matters most here: people mostly do not object to subscriptions
in principle, they object to ones that feel unfair or coercive, and that
objection is sharpest when the value is static rather than growing. Reading a
number you already pay for is static value. Charging monthly rent on it would be
the coercive case, so quotabot does not charge at all.

**Features nobody asked for.** Notepad is the canonical example. It shipped as a
tool that opened a file, and grew an account, sync, tabs, and an AI assistant
until people measured it using 88 MB of memory for text a 1.7 MB alternative
handled, and left for replacements whose pitch was simply no account, no
sign-in, no telemetry. Bloat is not only slower, it is more to attack: a
vulnerability in a text editor is a direct consequence of a text editor doing
more than editing text. quotabot answers one question and is meant to stay
answerable at a glance.

**AI pushed into things that do not need it.** "Slop" was Merriam-Webster's word
of 2025. Excitement about AI among users fell from about half to under a fifth
in two years, roughly half of consumers now prefer products that keep generative
AI out of what they see, and a majority disengage as soon as they suspect
generated content. quotabot is a tool *about* AI subscriptions, which makes it
the most tempting possible place to bolt on a chatbot. It does not have one, and
it will not. Its quota reads spend zero usage tokens, which is a correctness
property before it is a philosophical one: a meter that consumed the thing it
measures would be lying.

**Telemetry, however it is dressed up.** The blunt version, from a much-agreed
comment thread on the subject: anonymized or not, opt-out telemetry is plain
spying. The recurring worries are consistent - what actually leaves the machine,
how it gets correlated once it lands, and who can repurpose it later. Every one
of those worries dissolves if nothing leaves. So nothing does.

**Cloud dependency as an expiry date.** The local-first argument is that
centralizing data takes away ownership, and that when a service shuts down the
software stops working and the data goes with it. There is no quotabot service
to shut down. Your history is on your disk, in formats you can read.

## What quotabot will never do

Not "does not currently". Changing any of these would be a different product,
and the repository treats them as invariants rather than preferences.

1. Require an account, a license key, or a payment to do its job.
2. Send telemetry, analytics, crash reports, or usage pings anywhere.
3. Make a model or inference call, or read your prompts, source code, or model
   output.
4. Become a required hop for your requests. It advises; your tools call.
5. Enable metered spending on your behalf without an explicit opt-in.
6. Write to another application's credential or state files.
7. Show an advertisement, an upsell, or a prompt to upgrade.
8. Hold your data hostage. Uninstall is documented and reversible, and your
   history stays in plain files you can copy or delete.

## Check it yourself

The point of a trust claim you can verify is that you do not have to trust it.

| Claim | How to check |
|---|---|
| No inference, ever | `quotabot explain` prints every file read and network destination per adapter. No generation endpoint appears, because none exists in the source. |
| Nothing unexpected leaves the machine | Same command lists the exact provider metadata endpoints contacted. Watch it live with any network monitor; the fleet read is all you will see. A desktop update check contacts GitHub only after you invoke it and sends no local quota or account data. |
| No account, no service | Turn off your network and run `quotabot`. Cached history and last-known quota still render, labeled stale. Nothing waits on a login. |
| Your data is yours | `quotabot --json` is the whole snapshot. History and analytics are plain files under your per-user config directory. |
| No hidden spend | `quotabot suggest --task=hard` defaults to a `quota` budget. Paid catalog entries require an explicit `--budget=any`. |
| It is all here | Apache 2.0, one repository, no closed component. The release archives carry checksums and build provenance attestations. |

## Where the money would come from

Nowhere, currently. quotabot is free and unfunded, which is the honest answer
and also the structural reason the promises above are cheap to keep: there is no
investor expecting the meter to become a funnel.

If that ever changes, the constraint is written down in advance. Anything paid
would have to be additive and optional, and it could not be purchased by
weakening a promise on this page. Selling attention, data, or routing preference
is not on the table, because each one would corrupt the number the product
exists to report. A quota advisor that could be paid to prefer a provider is
worth less than no advisor.

## The recurring question

Before anything is added: does this make the available-capacity decision truer,
clearer, safer, or easier to act on? A feature that only makes the product
larger is not a feature. See [ROADMAP.md](../ROADMAP.md) for what that rules in
and out, and [PRODUCT-STRATEGY.md](PRODUCT-STRATEGY.md) for the reasoning behind
the shape of the product.
