USE appdb;
CREATE TABLE IF NOT EXISTS items (name VARCHAR(255) UNIQUE);
INSERT IGNORE INTO items (name) VALUES
  ('Laptop'),
  ('Monitor'),
  ('Keyboard'),
  ('Mouse'),
  ('Headphones');
