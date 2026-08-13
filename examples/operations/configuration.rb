# frozen_string_literal: true

# The example cell's numbers, sized for the battery rather than for real work: small enough that the
# misbehaving operations trip their limits in seconds. Overridable through the environment so bin/load can
# turn the knobs without editing a file — a container passes these with `docker run --env`.
#
# The memory and file-size values are the ones the server suite proves workable: a worker boots under a
# 1200MB RLIMIT_DATA, and an allocation of 900MB dies past it.
HotCell.limits concurrency: Integer(ENV.fetch("EXAMPLE_CONCURRENCY", 2)),
               queue_size: Integer(ENV.fetch("EXAMPLE_QUEUE_SIZE", 2)),
               queue_wait: Float(ENV.fetch("EXAMPLE_QUEUE_WAIT", 2)),
               deadline: Float(ENV.fetch("EXAMPLE_DEADLINE", 3)),
               memory: Integer(ENV.fetch("EXAMPLE_MEMORY_MB", 1200)) * 1024**2,
               file_size: Integer(ENV.fetch("EXAMPLE_FILE_SIZE_MB", 8)) * 1024**2
