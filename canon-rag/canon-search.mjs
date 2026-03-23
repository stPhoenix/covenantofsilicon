#!/usr/bin/env node
/**
 * Canon of Silicon — RAG Search
 *
 * Searches the pre-built Canon index using cosine similarity.
 * Runs inside the NanoClaw container with no external dependencies.
 *
 * Usage:
 *   node canon-search.mjs --query "What does the Canon say about bias?" [options]
 *
 * Options:
 *   --query, -q     Search query (required)
 *   --level         Filter by chunk level: L1, L2, or all (default: all)
 *   --type          Filter by type: sin, virtue, parable, psalm, commandment, case, rite, role, prophecy, general
 *   --testament     Filter by testament number: I, II, III, IV, V, VI, VII, VIII, IX
 *   --top, -n       Number of results (default: 5)
 *   --index         Path to canon-index.json (default: /workspace/extra/canon-index/canon-index.json)
 *   --embed-url     Embedding endpoint URL (default: uses pre-computed query embedding)
 *   --full          Show full chunk text (default: truncated to 500 chars)
 */

import { readFileSync } from 'fs';
import { argv } from 'process';

// Parse args
const args = {};
for (let i = 2; i < argv.length; i++) {
  const arg = argv[i];
  if (arg.startsWith('--')) {
    const key = arg.slice(2);
    args[key] = argv[i + 1] || true;
    if (argv[i + 1] && !argv[i + 1].startsWith('--')) i++;
  } else if (arg === '-q') {
    args.query = argv[++i];
  } else if (arg === '-n') {
    args.top = argv[++i];
  }
}

const query = args.query || args.q;
const level = args.level || 'all';
const type = args.type || null;
const testament = args.testament || null;
const topN = parseInt(args.top || args.n || '5', 10);
const __dirname = new URL('.', import.meta.url).pathname;
const indexPath = args.index || `${__dirname}canon-index.json`;
const showFull = args.full === true || args.full === 'true';

if (!query) {
  console.error('Usage: node canon-search.mjs --query "your search query" [--level L1|L2] [--type sin|virtue|...] [--testament I|II|...] [--top 5]');
  process.exit(1);
}

// Load index
let index;
try {
  index = JSON.parse(readFileSync(indexPath, 'utf-8'));
} catch (err) {
  console.error(`Error loading index from ${indexPath}: ${err.message}`);
  console.error('Run the indexer first: python3 index-canon.py');
  process.exit(1);
}

// Cosine similarity
function cosineSim(a, b) {
  let dot = 0, magA = 0, magB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    magA += a[i] * a[i];
    magB += b[i] * b[i];
  }
  return dot / (Math.sqrt(magA) * Math.sqrt(magB));
}

// Simple term-frequency search as fallback (no embedding server needed)
function termSearch(queryText, chunks) {
  const queryTerms = queryText.toLowerCase().split(/\s+/).filter(t => t.length > 2);

  return chunks.map(chunk => {
    const text = chunk.text.toLowerCase();
    let score = 0;

    for (const term of queryTerms) {
      // Exact term matches
      const regex = new RegExp(`\\b${term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'gi');
      const matches = text.match(regex);
      score += (matches ? matches.length : 0) * 2;

      // Partial matches
      if (text.includes(term)) score += 1;
    }

    // Boost L1 chunks slightly (they have more context)
    if (chunk.level === 'L1') score *= 1.1;

    // Boost if tags match query terms
    for (const tag of chunk.tags || []) {
      if (queryTerms.some(t => tag.includes(t) || t.includes(tag))) {
        score += 3;
      }
    }

    return { ...chunk, score };
  }).filter(c => c.score > 0);
}

// Get query embedding from LM Studio if available
async function getQueryEmbedding(text, embedUrl) {
  try {
    const resp = await fetch(`${embedUrl}/v1/embeddings`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        input: [text],
        model: index.embedding_model,
      }),
    });
    if (!resp.ok) return null;
    const data = await resp.json();
    return data.data[0].embedding;
  } catch {
    return null;
  }
}

// Main search
async function search() {
  let chunks = index.chunks;

  // Apply filters
  if (level !== 'all') {
    chunks = chunks.filter(c => c.level === level);
  }
  if (type) {
    chunks = chunks.filter(c => c.type === type);
  }
  if (testament) {
    chunks = chunks.filter(c => c.testament === testament);
  }

  // Try vector search first (if LM Studio is reachable from container)
  const embedUrl = args['embed-url'] || 'http://host.docker.internal:1234';
  const queryEmb = await getQueryEmbedding(query, embedUrl);

  let results;
  if (queryEmb) {
    // Vector search
    results = chunks
      .map(chunk => ({
        ...chunk,
        score: cosineSim(queryEmb, chunk.embedding),
      }))
      .sort((a, b) => b.score - a.score)
      .slice(0, topN);
  } else {
    // Fallback: term-based search
    results = termSearch(query, chunks)
      .sort((a, b) => b.score - a.score)
      .slice(0, topN);
  }

  // Output results (without embeddings)
  const output = results.map((r, i) => {
    const { embedding, ...rest } = r;
    return {
      rank: i + 1,
      score: Math.round(r.score * 1000) / 1000,
      testament: r.testament,
      testament_name: r.testament_name,
      section: r.section,
      level: r.level,
      type: r.type,
      tags: r.tags,
      commandments_referenced: r.commandments_referenced,
      text: showFull ? r.text : r.text.slice(0, 500) + (r.text.length > 500 ? '...' : ''),
    };
  });

  console.log(JSON.stringify({ query, results_count: output.length, search_mode: queryEmb ? 'vector' : 'term', results: output }, null, 2));
}

search();
