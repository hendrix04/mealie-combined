###############################################
# Front-end builder
###############################################
FROM node:16 as builder-frontend

WORKDIR /app

COPY . .

WORKDIR /app/frontend

RUN yarn install \
  --prefer-offline \
  --frozen-lockfile \
  --non-interactive \
  --production=false \ 
  # https://github.com/docker/build-push-action/issues/471
  --network-timeout 1000000
  
RUN yarn build

RUN rm -rf node_modules && \
  NODE_ENV=production yarn install \
  --prefer-offline \
  --pure-lockfile \
  --non-interactive \
  --production=true

###############################################
# Base Image
###############################################
FROM combos/python_node:3.10-slim-bullseye_16-bullseye-slim as project-base

ENV MEALIE_HOME="/app"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=off \
    PIP_DISABLE_PIP_VERSION_CHECK=on \
    PIP_DEFAULT_TIMEOUT=100 \
    POETRY_HOME="/opt/poetry" \
    POETRY_VIRTUALENVS_IN_PROJECT=true \
    POETRY_NO_INTERACTION=1 \
    PYSETUP_PATH="/opt/pysetup" \
    VENV_PATH="/opt/pysetup/.venv" \
    PUID=99 \
    PGID=100

# prepend poetry and venv to path
ENV PATH="$POETRY_HOME/bin:$VENV_PATH/bin:$PATH"

# create user account
RUN useradd -u $PUID -U -d $MEALIE_HOME -s /bin/bash abc \
    && usermod -G users abc \
    && mkdir $MEALIE_HOME

###############################################
# Builder Image
###############################################
FROM project-base as builder-base
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
    curl \
    ca-certificates \
    build-essential \
    libpq-dev \
    libwebp-dev \
    # LDAP Dependencies
    libsasl2-dev libldap2-dev libssl-dev \ 
    gnupg gnupg2 gnupg1 \
    debian-keyring \
    debian-archive-keyring \
    apt-transport-https \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | apt-key add - \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list \
    && apt-key adv --keyserver keyserver.ubuntu.com --recv-keys ABA1F9B8875A6661
    && apt-get update \
    && apt-get install --no-install-recommends -y \
    caddy \
    && pip install -U --no-cache-dir pip

# install poetry - respects $POETRY_VERSION & $POETRY_HOME
ENV POETRY_VERSION=1.1.6
RUN curl -sSL https://raw.githubusercontent.com/python-poetry/poetry/master/install-poetry.py | python -

# copy project requirement files here to ensure they will be cached.
WORKDIR $PYSETUP_PATH
COPY ./poetry.lock ./pyproject.toml ./

# install runtime deps - uses $POETRY_VIRTUALENVS_IN_PROJECT internally
RUN poetry install -E pgsql --no-dev

###############################################
# CRFPP Image
###############################################
FROM hkotel/crfpp as crfpp

RUN echo "crfpp-container" 

###############################################
# Production Image
###############################################
FROM project-base as production
ENV PRODUCTION=true

# curl for used by healthcheck
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
    curl \
    ca-certificates \
    && apt-get autoremove \
    && rm -rf /var/lib/apt/lists/*

# copying poetry and venv into image
COPY --from=builder-base $POETRY_HOME $POETRY_HOME
COPY --from=builder-base $PYSETUP_PATH $PYSETUP_PATH

# copy CRF++ Binary from crfpp
ENV CRF_MODEL_URL=https://github.com/mealie-recipes/nlp-model/releases/download/v1.0.0/model.crfmodel

ENV LD_LIBRARY_PATH=/usr/local/lib
COPY --from=crfpp /usr/local/lib/ /usr/local/lib
COPY --from=crfpp /usr/local/bin/crf_learn /usr/local/bin/crf_learn
COPY --from=crfpp /usr/local/bin/crf_test /usr/local/bin/crf_test



# copying caddy into image
COPY --from=builder-base /usr/bin/caddy /usr/bin/caddy

# copy backend
COPY ./mealie $MEALIE_HOME/mealie
COPY ./poetry.lock ./pyproject.toml $MEALIE_HOME/
COPY ./gunicorn_conf.py $MEALIE_HOME
COPY ./run.sh $MEALIE_HOME

# copy frontend
COPY --from=builder-frontend /app/frontend $MEALIE_HOME/frontend

#! Future
# COPY ./alembic ./alembic.ini $MEALIE_HOME/

# venv already has runtime deps installed we get a quicker install
WORKDIR $MEALIE_HOME
RUN . $VENV_PATH/bin/activate && poetry install -E pgsql --no-dev
WORKDIR /

# copy frontend
# COPY --from=frontend-build /app/dist $MEALIE_HOME/dist
#COPY ./Caddyfile $MEALIE_HOME

# Grab CRF++ Model Release
RUN curl -L0 $CRF_MODEL_URL --output $MEALIE_HOME/mealie/services/parser_services/crfpp/model.crfmodel

VOLUME [ "$MEALIE_HOME/data/" ]
ENV BACKEND_PORT=80
ENV FRONTEND_PORT=3000
ENV API_URL="http://localhost:$BACKEND_PORT"
ENV Host 0.0.0.0

EXPOSE ${FRONTEND_PORT}

HEALTHCHECK CMD curl -f http://localhost:${BACKEND_PORT} || exit 1

RUN chown $PUID:$PGID -R $MEALIE_HOME \
    &&chmod +x $MEALIE_HOME/run.sh

ENTRYPOINT $MEALIE_HOME/run.sh
