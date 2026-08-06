# The base image carries Ruby, bundler, and the two server gems. Nothing else.
#
# A cell must carry a Ruby runtime and every gem in its loaded graph, all inside the blast radius, so treat
# this file as a budget rather than an inventory. The closest comparable design chose a static binary with no
# interpreter in the runtime image at all. The case for Ruby is that operations are the extension point and
# the applications that will write them are Ruby applications — an operation that cannot be written in the
# language of the code it replaces will not be written.
#
# It carries no converter. Which toolchain a cell holds is the thing that decides its blast radius, so that
# is a derived image's decision. See DEPLOYMENT.md.

ARG RUBY_VERSION=3.4
FROM ruby:${RUBY_VERSION}-slim

# High and outside any host user range, with no home directory and no shell.
RUN groupadd --gid 10001 hotcell && \
    useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin hotcell

# The mount point itself has to exist here, owned by the cell's user, because a new named volume takes its
# ownership from the directory it covers. Create only the parent and Docker creates the missing level as
# root, and the cell's first act is a bare EACCES creating a socket it will never create. A bind mount does
# not inherit anything at all — it keeps the host directory's ownership. See DEPLOYMENT.md.
RUN mkdir -p /run/hotcell/cell /hotcell/operations && chown -R hotcell:hotcell /run/hotcell /hotcell

# HOME is /tmp because the cell's user has no home directory, and bundler wants one. A worker replaces it
# with its slot's home before it serves anything, which is what keeps two concurrent converters from sharing
# a profile.
ENV HOME=/tmp \
    BUNDLE_PATH=/hotcell/bundle \
    BUNDLE_WITHOUT=development \
    HOTCELL_OPERATIONS=/hotcell/operations \
    HOTCELL_DIR=/run/hotcell/cell

WORKDIR /hotcell

COPY --chown=hotcell:hotcell docker/Gemfile Gemfile
COPY --chown=hotcell:hotcell hotcell-core hotcell-core
COPY --chown=hotcell:hotcell hotcell-server hotcell-server

USER hotcell
RUN bundle install

# The bundle is deliberately not frozen: a derived image adds operations with their own Gemfile and has to be
# able to resolve again.
CMD ["bundle", "exec", "hotcell"]
