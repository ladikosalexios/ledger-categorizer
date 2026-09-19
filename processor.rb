#!/usr/bin/env ruby
# frozen_string_literal: true

require 'csv'
require 'bigdecimal'

# Turns a raw bank/card transaction feed into categorized ledger lines.
class TransactionProcessor
  DEFAULT_MERCHANTS_PATH = File.join(__dir__, 'merchants.csv')
  TRANSFER_MEMO = /PAYMENT|TRANSFER/i.freeze
  OUTPUT_HEADERS = %w[transaction_id date type category amount needs_review].freeze

  def self.load_merchants(path = DEFAULT_MERCHANTS_PATH)
    CSV.foreach(path, headers: true, encoding: 'bom|utf-8').to_h do |row|
      [row['merchant'], row['category']]
    end
  end

  def self.run(input_path, output_path, merchants: load_merchants)
    rows = CSV.foreach(input_path, headers: true, encoding: 'bom|utf-8')
    lines = new(merchants).process(rows)

    CSV.open(output_path, 'w') do |csv|
      csv << OUTPUT_HEADERS
      lines.each { |line| csv << line.values_at(*OUTPUT_HEADERS) }
    end
    lines
  end

  # merchants: { 'MERCHANT NAME PREFIX' => 'Category' }
  def initialize(merchants)
    @categories = merchants.to_h { |name, category| [name.to_s.strip.upcase, category] }
    # Longest first, so a more specific name always beats a shorter overlapping prefix
    # ("NORTHWIND FREIGHT" before "NORTHWIND").
    @merchant_keys = @categories.keys.sort_by { |name| -name.length }
  end

  # rows: anything enumerable yielding hash-like rows keyed by the feed's column names.
  def process(rows)
    dedupe(rows).map { |row| ledger_line(row) }
  end

  # One id, one row: keep the version from the highest sync_batch. A row only replaces
  # the stored one when its batch is strictly greater, so ties keep the first seen.
  # Replacing a Hash value keeps the key's original position, preserving feed order.
  def dedupe(rows)
    latest = {}
    rows.each do |row|
      id = row['id']
      stored = latest[id]
      latest[id] = row if stored.nil? || row['sync_batch'].to_i > stored['sync_batch'].to_i
    end
    latest.values
  end

  def ledger_line(row)
    category = merchant_category(row['merchant'])
    type, category, needs_review = classify(row, category)

    {
      'transaction_id' => row['id'],
      'date' => row['date'],
      'type' => type,
      'category' => category,
      'amount' => row['amount'], # original string, never a re-serialized number
      'needs_review' => needs_review.to_s
    }
  end

  private

  # A known merchant is a third party, so it is never an own-account transfer even if
  # the memo says PAYMENT (e.g. "ACH PAYMENT OAK STREET HOLDINGS" is rent).
  def classify(row, category)
    return ['transfer', 'Transfer', false] if category.nil? && transfer_memo?(row['memo'])

    [base_type(row), category || 'Uncategorized', category.nil?]
  end

  # Positive is money out, negative is money in, on both accounts.
  def base_type(row)
    return 'purchase' unless amount_for(row).negative?

    case row['account'].to_s.strip.downcase
    when 'card' then 'refund'
    when 'bank' then 'deposit'
    else 'purchase'
    end
  end

  def merchant_category(merchant)
    name = merchant.to_s.strip.upcase
    key = @merchant_keys.find { |candidate| name.start_with?(candidate) }
    key && @categories[key]
  end

  def transfer_memo?(memo)
    memo.to_s.match?(TRANSFER_MEMO)
  end

  # Parsed only to read the sign. BigDecimal, not Float: this is money.
  def amount_for(row)
    BigDecimal(row['amount'].to_s.strip)
  rescue ArgumentError
    raise ArgumentError, "invalid amount #{row['amount'].inspect} for transaction #{row['id']}"
  end
end

if $PROGRAM_NAME == __FILE__
  input = ARGV[0] || File.join(__dir__, 'sample', 'transactions.csv')
  output = ARGV[1] || 'ledger_lines.csv'
  lines = TransactionProcessor.run(input, output)
  review = lines.count { |line| line['needs_review'] == 'true' }
  warn "Wrote #{lines.size} ledger lines to #{output} (#{review} need review)"
end
