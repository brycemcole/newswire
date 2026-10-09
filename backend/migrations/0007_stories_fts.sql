CREATE VIRTUAL TABLE stories_fts USING fts5(title, summary, body, content='stories', content_rowid='rowid', tokenize='porter unicode61');
INSERT INTO stories_fts (stories_fts) VALUES ('rebuild');
