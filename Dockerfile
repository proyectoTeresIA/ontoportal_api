ARG RUBY_VERSION=3.1
ARG DISTRO_NAME=bullseye

FROM ruby:$RUBY_VERSION-$DISTRO_NAME

RUN apt-get update -yqq && apt-get install -yqq --no-install-recommends \
  git \
  build-essential \
  openjdk-11-jre-headless \
  raptor2-utils \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /srv/ontoportal/ontologies_api
RUN mkdir -p /srv/ontoportal/bundle
RUN mkdir -p /srv/ontoportal/ontologies_api/.bundle
COPY Gemfile* /srv/ontoportal/ontologies_api/
WORKDIR /srv/ontoportal/ontologies_api

ENV BUNDLE_PATH=/srv/ontoportal/bundle
ENV BUNDLE_APP_CONFIG=/srv/ontoportal/ontologies_api/.bundle
ENV BUNDLE_WITHOUT="development test"
ENV BUNDLE_DEPLOYMENT=true

RUN bundle install --jobs 4 --retry 3

COPY . /srv/ontoportal/ontologies_api

RUN cp /srv/ontoportal/ontologies_api/config/environments/config.rb.sample /srv/ontoportal/ontologies_api/config/environments/development.rb

EXPOSE 9393
CMD ["bundle", "exec", "rackup", "-p", "9393", "--host", "0.0.0.0"]
