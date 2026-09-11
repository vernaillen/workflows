# Fixture for .github/workflows/self-test.yml: the smallest image that exercises
# a build argument, a mounted build secret and an HTTP probe. Not an application.

FROM node:26-slim

ARG SELF_TEST_ARG=unset
RUN echo "build-arg SELF_TEST_ARG=${SELF_TEST_ARG}"

# Build secrets are optional by default, so this proves the plumbing without the
# self-test needing a secret of its own.
RUN --mount=type=secret,id=self_test_secret \
    if [ -s /run/secrets/self_test_secret ]; then \
      echo "build secret mounted"; \
    else \
      echo "no build secret mounted (expected in the self-test)"; \
    fi

WORKDIR /app
COPY server.mjs ./

ENV PORT=3000
EXPOSE 3000
CMD ["node", "server.mjs"]
