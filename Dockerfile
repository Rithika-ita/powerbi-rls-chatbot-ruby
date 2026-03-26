FROM ruby:3.2-slim

RUN apt-get update -qq && apt-get install -y build-essential curl

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

EXPOSE 4567

CMD ["ruby", "app.rb", "-o", "0.0.0.0"]
