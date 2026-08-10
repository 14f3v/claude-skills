-- Initial migration.
-- Apply locally:   npx wrangler d1 migrations apply DB --local
-- Apply to remote: npx wrangler d1 migrations apply DB --remote
create table if not exists items (
	id integer primary key autoincrement,
	name text not null,
	created_at text not null default (datetime('now'))
);
