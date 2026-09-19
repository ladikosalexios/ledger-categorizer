# ledger-categorizer

Turns a raw bank and card transaction feed into categorized ledger lines for a small business. Rules-based, standard-library Ruby, no gems.

Given a feed like [sample/transactions.csv](sample/transactions.csv), it produces one ledger line per transaction with a `type` (`purchase`, `refund`, `deposit`, `transfer`), a `category`, and a `needs_review` flag for anything it could not categorize.

## Run it

```bash
./run.sh                      # sample/transactions.csv -> ledger_lines.csv
./run.sh input.csv output.csv # your own feed
ruby processor_test.rb        # tests
```

Requires Ruby 3.x. Uses only `csv`, `bigdecimal`, and `minitest`, which ship with Ruby.

## Rules

1. **Re-syncs.** Providers resend the same `id` in later `sync_batch`es as a transaction goes from pending to posted, sometimes with a new memo or amount. One id, one ledger line: the highest batch wins, and the line keeps its original position in the feed.
2. **Sign convention.** Positive is money leaving the business, negative is money coming in, on both accounts.
3. **Categories** come from [merchants.csv](merchants.csv). A transaction matches when its merchant field starts with a listed name, ignoring case, so store numbers and other trailing junk are fine. No match means `Uncategorized` and `needs_review = true`.
4. **Transfers.** Money moving between the business's own accounts (card payments, moves to and from savings) is a `transfer`, not an expense or income. These are detected by `PAYMENT` or `TRANSFER` in the memo, but only when the merchant is not on the list.
5. A negative card amount is a `refund` and gets the category the purchase would have had. A negative bank amount is a `deposit`. Everything else is a `purchase`.

## Design decisions

- **Known merchants beat the memo keyword.** "ACH PAYMENT OAK STREET HOLDINGS" is rent to a landlord, not an internal transfer. The keyword is necessary for a transfer but not sufficient, so the merchant list is checked first. The better long-term fix is an explicit map of the business's own accounts.
- **Amounts are never re-serialized.** `"233.00".to_f.to_s` is `"233.0"`, and Float is the wrong type for money anyway. The original string goes straight to the output; `BigDecimal` is used only to read the sign.
- **Longest merchant prefix wins**, so `NORTHWIND FREIGHT` (Shipping) is not swallowed by `NORTHWIND` (Inventory).
- **Deterministic dedup.** Batches compare as integers (`10 > 9`), an older batch arriving late never overwrites a newer one, and two rows with the same id and batch keep the first seen.
- **No silent blanks.** A zero amount or an unrecognized account falls through to `purchase` rather than an empty type; an unparseable amount raises with the transaction id.

The sample feed and [its expected output](sample/expected_ledger_lines.csv) were written by hand to cover each of these cases, and the test suite checks the full run against it byte for byte.

Built with Claude Code as a pair programmer.
