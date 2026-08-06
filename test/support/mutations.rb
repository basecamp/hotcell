# frozen_string_literal: true

# Reads a minitest run and says whether it noticed.
#
# Not `output.include?("0 failures, 0 errors")`, which is how this was written first and which is wrong in a
# way that reads as flakiness: "10 failures, 0 errors" contains that substring, so every mutation the suite
# caught with a count ending in zero was reported as having survived. A harness that cries wolf gets ignored,
# and then a mutation that really does survive is ignored with it.
module Mutations
  SUMMARY = /(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors/

  # Returns [caught, summary]. A run that never reported at all counts as caught: the mutation stopped the
  # suite from running, which fails just as loudly.
  def self.caught?(output)
    match = output.match(SUMMARY)
    return [ true, "the suite did not report" ] if match.nil?

    _runs, _assertions, failures, errors = match.captures.map(&:to_i)
    [ failures.positive? || errors.positive?, match[0] ]
  end
end
