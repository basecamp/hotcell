# frozen_string_literal: true

# Reads a minitest run and says whether it noticed.
#
# Two things this has been wrong about, both of which made the harness lie in the reassuring direction.
#
# It used to ask whether the output contained "0 failures, 0 errors", which "10 failures, 0 errors" also
# contains — so every mutation the suite caught with a count ending in zero was reported as having survived.
#
# And it used to treat a run that never reported at all as caught, reasoning that a mutation which stops the
# suite from booting fails just as loudly. That is true of a real mutation, and it is also exactly what a
# mutation file with a mistake in it looks like — which is how one that tested nothing sat in the list
# reporting success. A run that did not report is now its own answer, and the task stops on it.
module Mutations
  SUMMARY = /(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors/

  # Returns [status, summary], where status is :caught, :survived, or :broken.
  def self.result(output)
    match = output.match(SUMMARY)
    return [ :broken, "the suite never reported — look at the mutation itself" ] if match.nil?

    _runs, _assertions, failures, errors = match.captures.map(&:to_i)
    noticed = failures.positive? || errors.positive?

    [ (noticed ? :caught : :survived), match[0] ]
  end
end
