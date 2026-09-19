# frozen_string_literal: true

# Keep minitest from auto-loading plugins of globally installed gems (e.g. Rails),
# which can fail to activate outside a bundle. This suite needs none.
ENV['MT_NO_PLUGINS'] ||= '1'

require 'minitest/autorun'
require 'tempfile'
require_relative 'processor'

class TransactionProcessorTest < Minitest::Test
  SAMPLE_FEED = File.join(__dir__, 'sample', 'transactions.csv')
  SAMPLE_EXPECTED = File.join(__dir__, 'sample', 'expected_ledger_lines.csv')

  MERCHANTS = {
    'NORTHWIND' => 'Inventory',
    'NORTHWIND FREIGHT' => 'Shipping',
    'OAK STREET HOLDINGS' => 'Rent',
    'CITY POWER & LIGHT' => 'Utilities',
    'TILLPOINT PAYOUT' => 'Card sales'
  }.freeze

  def setup
    @processor = TransactionProcessor.new(MERCHANTS)
  end

  def row(overrides = {})
    {
      'id' => 't_1', 'sync_batch' => '1', 'date' => '2026-06-01', 'account' => 'card',
      'merchant' => 'NORTHWIND PARTS 4471', 'memo' => 'NORTHWIND PARTS 4471', 'amount' => '10.00'
    }.merge(overrides)
  end

  def line_for(overrides = {})
    @processor.ledger_line(row(overrides))
  end

  # --- transfers -----------------------------------------------------------

  def test_known_merchant_with_payment_in_memo_is_a_purchase_not_a_transfer
    line = line_for('account' => 'bank', 'merchant' => 'OAK STREET HOLDINGS LLC',
                    'memo' => 'ACH PAYMENT OAK STREET HOLDINGS', 'amount' => '3200.00')

    assert_equal %w[purchase Rent false], line.values_at('type', 'category', 'needs_review')
  end

  def test_card_payment_is_a_transfer_on_both_legs
    bank_leg = line_for('account' => 'bank', 'merchant' => 'ONLINE PAYMENT TO CARD 7702',
                        'memo' => 'ONLINE PAYMENT TO CARD 7702', 'amount' => '2500.00')
    card_leg = line_for('account' => 'card', 'merchant' => 'PAYMENT RECEIVED',
                        'memo' => 'ONLINE PAYMENT - THANK YOU', 'amount' => '-2500.00')

    [bank_leg, card_leg].each do |line|
      assert_equal %w[transfer Transfer false], line.values_at('type', 'category', 'needs_review')
    end
  end

  def test_savings_moves_are_transfers_and_memo_match_ignores_case
    line = line_for('account' => 'bank', 'merchant' => 'Transfer from savings 3301',
                    'memo' => 'online transfer from savings 3301', 'amount' => '-1500.00')

    assert_equal %w[transfer Transfer false], line.values_at('type', 'category', 'needs_review')
  end

  def test_autopay_and_payout_memos_are_not_transfers
    autopay = line_for('account' => 'bank', 'merchant' => 'CITY POWER & LIGHT',
                       'memo' => 'AUTOPAY CITY POWER & LIGHT', 'amount' => '412.90')
    payout = line_for('account' => 'bank', 'merchant' => 'SOME NEW PAYOUT', 'memo' => 'SOME NEW PAYOUT',
                      'amount' => '-100.00')

    assert_equal %w[purchase Utilities], autopay.values_at('type', 'category')
    assert_equal %w[deposit Uncategorized true], payout.values_at('type', 'category', 'needs_review')
  end

  # --- amounts -------------------------------------------------------------

  def test_amount_string_passes_through_untouched
    assert_equal '233.00', line_for('amount' => '233.00')['amount']
    assert_equal '-1840.20', line_for('amount' => '-1840.20', 'account' => 'bank')['amount']
  end

  def test_zero_amount_defaults_to_purchase
    assert_equal 'purchase', line_for('amount' => '0.00')['type']
  end

  def test_negative_amount_on_unrecognized_account_defaults_to_purchase
    assert_equal 'purchase', line_for('amount' => '-5.00', 'account' => 'loan')['type']
  end

  def test_invalid_amount_raises_with_the_transaction_id
    error = assert_raises(ArgumentError) { line_for('id' => 't_bad', 'amount' => 'abc') }
    assert_match(/t_bad/, error.message)
  end

  # --- base types and categories ------------------------------------------

  def test_card_refund_gets_the_purchase_category
    line = line_for('memo' => 'NORTHWIND CREDIT DAMAGED RIMS', 'amount' => '-120.50')

    assert_equal %w[refund Inventory false], line.values_at('type', 'category', 'needs_review')
  end

  def test_refund_from_unlisted_merchant_needs_review
    line = line_for('merchant' => 'BIGBOX ONLINE*4K2', 'memo' => 'BIGBOX ONLINE REFUND', 'amount' => '-23.99')

    assert_equal %w[refund Uncategorized true], line.values_at('type', 'category', 'needs_review')
  end

  def test_negative_bank_amount_is_a_deposit
    line = line_for('account' => 'bank', 'merchant' => 'TILLPOINT PAYOUT', 'memo' => 'TILLPOINT DAILY PAYOUT',
                    'amount' => '-1840.25')

    assert_equal ['deposit', 'Card sales', 'false'], line.values_at('type', 'category', 'needs_review')
  end

  def test_merchant_match_is_a_case_insensitive_prefix_and_tolerates_whitespace
    assert_equal 'Inventory', line_for('merchant' => '  northwind parts 4471 ')['category']
  end

  def test_longest_merchant_prefix_wins
    assert_equal 'Shipping', line_for('merchant' => 'NORTHWIND FREIGHT 88')['category']
    assert_equal 'Inventory', line_for('merchant' => 'NORTHWIND PARTS 4471')['category']
  end

  def test_merchant_name_must_be_a_prefix_not_a_substring
    assert_equal 'Uncategorized', line_for('merchant' => 'THE NORTHWIND STORE', 'memo' => 'x')['category']
  end

  def test_nil_merchant_and_memo_are_uncategorized
    line = line_for('merchant' => nil, 'memo' => nil)

    assert_equal %w[purchase Uncategorized true], line.values_at('type', 'category', 'needs_review')
  end

  # --- dedup ---------------------------------------------------------------

  def test_highest_sync_batch_wins_and_keeps_first_seen_position
    rows = [
      row('id' => 'a', 'sync_batch' => '1', 'memo' => 'PENDING', 'amount' => '1.00'),
      row('id' => 'b', 'sync_batch' => '1'),
      row('id' => 'a', 'sync_batch' => '2', 'memo' => 'POSTED', 'amount' => '48.17')
    ]

    result = @processor.dedupe(rows)

    assert_equal %w[a b], result.map { |r| r['id'] }
    assert_equal '48.17', result.first['amount']
  end

  def test_sync_batch_tie_keeps_the_first_row_seen
    rows = [
      row('id' => 'a', 'sync_batch' => '2', 'amount' => '1.00'),
      row('id' => 'a', 'sync_batch' => '2', 'amount' => '2.00')
    ]

    assert_equal ['1.00'], @processor.dedupe(rows).map { |r| r['amount'] }
  end

  def test_older_batch_arriving_later_does_not_overwrite
    rows = [
      row('id' => 'a', 'sync_batch' => '2', 'amount' => '2.00'),
      row('id' => 'a', 'sync_batch' => '1', 'amount' => '1.00')
    ]

    assert_equal ['2.00'], @processor.dedupe(rows).map { |r| r['amount'] }
  end

  def test_sync_batch_compares_numerically_not_as_strings
    rows = [
      row('id' => 'a', 'sync_batch' => '9', 'amount' => '9.00'),
      row('id' => 'a', 'sync_batch' => '10', 'amount' => '10.00')
    ]

    assert_equal ['10.00'], @processor.dedupe(rows).map { |r| r['amount'] }
  end

  # --- end to end against the sample feed ---------------------------------

  def test_sample_feed_matches_the_hand_written_expected_output
    Tempfile.create(['ledger', '.csv']) do |out|
      TransactionProcessor.run(SAMPLE_FEED, out.path)
      assert_equal File.read(SAMPLE_EXPECTED), File.read(out.path)
    end
  end
end
