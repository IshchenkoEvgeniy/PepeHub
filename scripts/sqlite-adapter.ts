import { DatabaseSync, type SQLInputValue } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import type { Database, Statement } from '../services/sync-worker/src/database.ts';
class SqliteStatement implements Statement {
  db: DatabaseSync; sql: string; values: SQLInputValue[];
  constructor(db: DatabaseSync,sql: string,values: SQLInputValue[]=[]) { this.db=db;this.sql=sql;this.values=values; }
  bind(...values: unknown[]): Statement { return new SqliteStatement(this.db,this.sql,values as SQLInputValue[]); }
  async first<T>(): Promise<T|null> { return (this.db.prepare(this.sql).get(...this.values) as T) ?? null; }
  async all<T>(): Promise<{results:T[]}> { return {results:this.db.prepare(this.sql).all(...this.values) as T[]}; }
  async run(): Promise<unknown> { return this.db.prepare(this.sql).run(...this.values); }
}
export class SqliteDatabase implements Database {
  sqlite: DatabaseSync;
  constructor(path=':memory:') {
    this.sqlite=new DatabaseSync(path);
    this.sqlite.exec('PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;');
    const version=Number(this.sqlite.prepare('PRAGMA user_version').get()?.user_version ?? 0);
    if(version===0) {
      this.sqlite.exec('BEGIN');
      try {
        this.sqlite.exec(readFileSync(new URL('../services/sync-worker/migrations/0001_initial.sql',import.meta.url),'utf8'));
        this.sqlite.exec('PRAGMA user_version=1; COMMIT');
      } catch(e) {this.sqlite.exec('ROLLBACK');throw e;}
    }
  }
  prepare(sql: string): Statement { return new SqliteStatement(this.sqlite,sql); }
  async batch(statements: Statement[]): Promise<unknown[]> {
    // No await within this synchronous transaction: concurrent JS requests cannot interleave it.
    this.sqlite.exec('BEGIN IMMEDIATE');
    try {
      const result=statements.map(s=>{
        const q=s as SqliteStatement;
        return {results:this.sqlite.prepare(q.sql).all(...q.values)};
      });
      this.sqlite.exec('COMMIT');return result;
    } catch(error) {this.sqlite.exec('ROLLBACK');throw error;}
  }
  close(): void { this.sqlite.close(); }
}
