---
publishDate: 2023-05-26T00:12:00Z
title: How to add SQLite3 Full Text Search to existing Ecto tables
description: In this blog post we are going to add full text search to an existing table in our Phoenix app.
image: ~/assets/images/2023/elixir sqlite full text search.png
tags:
  - tutorial
  - elixir
---

We will leverage the built-in [FTS5](https://www.sqlite.org/fts5.html) plugin to search through messages in a simple chat app.

This blog post is inspired by Fly.io's [SQLite3 Full Text Search With Phoenix](https://fly.io/phoenix-files/sqlite3-full-text-search-with-phoenix/) but instead of creating a new virtual table from scratch we keep our existing _messages_ table and add a new virtual table for our search functionality on top.

This has some advantages:

- The new search functionality and the old data & code are more separated.

- We can keep our Ecto abstractions and can easily add fields to our _messages_.

- In many cases adding full text search retroactively might be the only way.

One disadvantage is that we have to keep both tables in sync. We will use SQLite triggers whenever we update our _messages_ data.

## Table of Contents

To see how everything works, let's start to creates a basic app that saves chat messages:

## Creating our chat app

First, we start a new app with a SQLite3 database.

```bash
mix phx.new chatter --database sqlite3
cd chatter
```

In our app directory, we generate a context Chat and a Message model with an Ecto schema and database migration:

```bash
mix phx.gen.context Chat Message messages title:string body:text
```

Our migration file in `./priv/repo/migrations` should look like this:

```elixir
defmodule Chatter.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages) do
      add :title, :string
      add :body, :text

      timestamps()
    end
  end
end
```

Next, we run the migration:

```bash
mix ecto.migrate

13:07:51.313 [info] == Running 20230523060054 Chatter.Repo.Migrations.CreateMessages.change/0 forward

13:07:51.317 [info] create table messages

13:07:51.319 [info] == Migrated 20230523060054 in 0.0s
```

Let's insert some messages so we can add full text search to some existing data later:

```elixir
iex -S mix

Chatter.Chat.create_message(%{title: "Test", body: "We will make this text searchable."})
Chatter.Chat.create_message(%{title: "Another message", body: "We'll leverage FTS5 virtual tables to rank the content depending on search queries."})
```

It works! Now it's time to add full text search without any external dependencies:

## Implementing our search

I recommend taking a look at Fly.io's [SQLite3 Full Text Search With Phoenix](https://fly.io/phoenix-files/sqlite3-full-text-search-with-phoenix/) post that explains how the FTS5-plugin uses virtual tables to search through our data.

Instead of creating a FTS5 virtual table from scratch that keeps our search index AND the data in one place we will make use of the External Content Tables functionality.

## How do External Content Tables work?

This feature creates a FTS5 table that stores only FTS index entries. Whenever we search for some content in our messages, the FTS5 plugin queries the data from our existing _messages_ table.

As mentioned above, this leaves our _messages_ untouched and we can keep using all the conveniences provided by Ecto.

For example, I first tried the from-scratch-migration from Fly.io's post but got an error when I added another column to the _messages_ table via `ecto.gen.migration`. I would have to work with manual SQL commands whenever I wanted to change something.

The approach in this post let's me use _messages_ in the traditional Ecto way.

Furthermore, since we don't store any data in our FTS5 virtual table, we keep our database small.

## Adding a FTS5 virtual table to our Phoenix app

Let's generate a new migration:

```bash
mix ecto.gen.migration create_messages_search
```

The [ecto_sqlite3](https://hex.pm/packages/ecto_sqlite3) adapter doesn't have any convenience functions to add a virtual table - we have to do it by hand. So let's replace the generated code in the migration with this:

```elixir
defmodule Chatter.Repo.Migrations.CreateMessagesSearch do
  use Ecto.Migration

  def up do
    execute("CREATE VIRTUAL TABLE messages_search USING fts5(body, content='messages', content_rowid='id');")
    execute("""
      CREATE TRIGGER messages_search_ai AFTER INSERT ON messages BEGIN
        INSERT INTO messages_search(rowid, body) VALUES (new.id, new.body);
      END;
      """)
    execute("""
      CREATE TRIGGER messages_search_ad AFTER DELETE ON messages BEGIN
        INSERT INTO messages_search(messages_search, rowid, body) VALUES('delete', old.id, old.body);
      END;
      """)
    execute("""
      CREATE TRIGGER messages_search_au AFTER UPDATE ON messages BEGIN
        INSERT INTO messages_search(messages_search, rowid, body) VALUES('delete', old.id, old.body);
        INSERT INTO messages_search(rowid, body) VALUES (new.id, new.body);
      END;
      """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS messages_search_ai;")
    execute("DROP TRIGGER IF EXISTS messages_search_ad;")
    execute("DROP TRIGGER IF EXISTS messages_search_au;")
    execute("DROP TABLE IF EXISTS messages_search;")
  end
end
```

Note: I've done my best to implement the steps found in the FTS5 docs in our migration. I'm by no means an SQLite expert, so be careful to blindly copy these commands.

Let's go through our manual migration:

We have `up/0` and `down/0` functions to migrate our database or to roll it back. We could put everything in one change() function, but I like to separate the steps (to make it easier to grasp what is going on).

The [execute/1](https://hexdocs.pm/ecto_sql/Ecto.Migration.html#execute/1) command allows us to use several SQL commands:

### The virtual table for the FTS5 search index

```elixir
execute("CREATE VIRTUAL TABLE messages_search USING fts5(body, content='messages', content_rowid='id');")
```

In the first step we create a new virtual table named _messages_search_ with a column _body_.

This part `content='messages', content_rowid='id'` tells FTS5 to get the data from our existing _messages_ table with the primary_key _id_.

We could also add other fields like the _title_ - as long as they exist as a column in the queried table _messages_.

Okay - we have an FTS5 virtual table with an empty index. Now it's time to sync it with our data.

### Keeping the index up-to-date with SQLite triggers

```elixir
execute("""
CREATE TRIGGER messages_search_ai AFTER INSERT ON messages BEGIN
  INSERT INTO messages_search(rowid, body) VALUES (new.id, new.body);
END;
""")
```

This command creates a trigger that fires whenever we insert data in our old _messages_ table. Whenever a new message gets inserted, SQLite automatically updates our FTS5 virtual table so it knows where to find the message _id_ and the message _body_.

We also create 2 other triggers:

```elixir
execute("""
CREATE TRIGGER messages_search_ad AFTER DELETE ON messages BEGIN
  INSERT INTO messages_search(messages_search, rowid, body) VALUES('delete', old.id, old.body);
END;
""")
execute("""
CREATE TRIGGER messages_search_au AFTER UPDATE ON messages BEGIN
  INSERT INTO messages_search(messages_search, rowid, body) VALUES('delete', old.id, old.body);
  INSERT INTO messages_search(rowid, body) VALUES (new.id, new.body);
END;
""")
```

They update the FTS5 index each time a message gets deleted or updated.

With these commands we can create the virtual table and the triggers to keep it synced.

### Rollback the database

```elixir
def down do
  execute("DROP TRIGGER IF EXISTS messages_search_ai;")
  execute("DROP TRIGGER IF EXISTS messages_search_ad;")
  execute("DROP TRIGGER IF EXISTS messages_search_au;")
  execute("DROP TABLE IF EXISTS messages_search;")
end
```

In the down() function we instruct Ecto to delete all triggers and drop the _messages_search_ table when we choose to rollback the database.

## Syncing our tables manually

Let's migrate our database with

```bash
mix ecto.migrate
```

We now have all necessary tables and triggers.

Let's check our database with [DB Browser for SQLite](https://sqlitebrowser.org/):

![DB Browser for SQLite](/images/2023/sqlite-browser.png)

We can see our _messages_ table created by Ecto and also multiple _messages_search_-tables created by our migration (and the FTS5 plugin).

We can also see our triggers which keep our index in sync.

Instead of triggers, we could also opt for a simpler solution like syncing the tables periodically. In fact we have to do it once to index our two existing messages in our database.

Let's open iex to update our index manually:

```bash
iexs -S mix
```

We'll use a single SQL command that builds our FTS5 search index for our existing messages:

```elixir
query = "INSERT INTO messages_search(rowid, body) SELECT id, body FROM messages;"
Ecto.Adapters.SQL.query!(Chatter.Repo, query, [])
```

## Ecto schema for our FTS5 table

Let's add a schema in `.lib/chatter/search/messages_search.ex` to use our _messages_search_ table with Ecto:

```elixir
defmodule Chatter.Search.MessagesSearch do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true, source: :rowid}
  schema "messages_search" do
    field :body, :string
    field :rank, :float, virtual: true
  end
end
```

We map our schema's primary key to :id (based on the :rowid in the database that references our _messages_ :id) so we can use it with Ecto.

FTS5 also creates a :rank column that lets us order our results, the virtual field in our schema makes sure we can use it in our queries.

## Querying the Full Text Search index

Now with everything in place, we can search within our messages. Let's add a Search context:

```elixir
defmodule Chatter.Search do
  import Ecto.Query, warn: false
  alias Chatter.Repo

  alias Chatter.Search.MessagesSearch

  def search_messages(query) do
    from(MessagesSearch,
      select: [:body, :rank, :id],
      where: fragment("messages_search MATCH ?", ^query),
      order_by: [asc: :rank]
    )
    |> Repo.all()
  end
end

```

`fragment()` searches through our FTS5 index and returns a list of matching messages (or an empty list if nothing matches our query string).

```elixir
iex(1)> Chatter.Search.search_messages('virtual')

[
  %Chatter.Search.MessagesSearch{
    __meta__: #Ecto.Schema.Metadata<:loaded, *messages_search*>,
    id: 2,
    body: "We'll leverage FTS5 virtual tables to rank the content depending on search queries.",
    rank: -8.593749999999999e-7
  }
]

```

Everything works! We can search for strings in our _messages_ and our FTS5 index will get updated automatically.

## Other things to try out

Add more fields to our index. You could include the :title column in the migration. You could also try to add another column in a completely new migration (that executes manual SQL commands).

Our implementation only queries full strings. For substrings like "virt" (instead of "virtual"). It's also case-insensitive. From looking at the FTS5 docs, you could leverage the built-in [trigram tokenizer](https://www.sqlite.org/fts5.html#the_trigram_tokenizer) to add this functionality.

**That's it! I hope this little project was helpful. Please share this post with others and let me know how you would improve or build upon this code.**
