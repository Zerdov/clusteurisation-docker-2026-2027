-- Execute UNE SEULE FOIS, a la premiere initialisation du volume.
CREATE TABLE IF NOT EXISTS comptes (
  id      SERIAL PRIMARY KEY,
  pseudo  TEXT NOT NULL UNIQUE,
  cree_le TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS publications (
  id        SERIAL PRIMARY KEY,
  auteur_id INTEGER NOT NULL REFERENCES comptes(id),
  titre     TEXT    NOT NULL,
  cree_le   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_publications_date ON publications (cree_le DESC);

INSERT INTO comptes (pseudo) SELECT 'ada' WHERE NOT EXISTS (SELECT 1 FROM comptes);
