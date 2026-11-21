// copyright:begin
// File: Scripts/youtrack_knowledge_base_runner.js
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com
// copyright:end

/* Evaluate and await this expression through functions.exec.
 * Required: globalThis.YOUTRACK_KB_SYNC_OPTIONS = {root: "/absolute/repository"}.
 * Supply candidateRevision for a project publication and bootstrap:true for the
 * first publication. Optional dryRun:true previews. Set reconcileRoot or
 * reconcile[key] to identify one uncertain creation.
 * Supply task:{issueId,runId,approvedPlanCommit,candidateCommit,stage,progress}
 * for the issue-specific Air publication path.
 * Authentication stays in the YouTrack connector. No source text is executed.
 */
(async function synchronizeKnowledgeBase() {
  // Validate explicit invocation options before starting any local or remote work.
  const supplied = globalThis.YOUTRACK_KB_SYNC_OPTIONS;
  if (!supplied || typeof supplied !== "object" || Array.isArray(supplied)
      || typeof supplied.root !== "string" || !supplied.root
      || supplied.root.includes("\0")
      || !(supplied.root.startsWith("/") || /^[A-Za-z]:[\\/]/.test(supplied.root))) {
    throw new Error("Set YOUTRACK_KB_SYNC_OPTIONS.root to the absolute repository root");
  }
  for (const flag of ["dryRun", "bootstrap"]) {
    if (supplied[flag] !== undefined && typeof supplied[flag] !== "boolean") {
      throw new Error("Knowledge Base option " + flag + " must be a boolean");
    }
  }
  if (supplied.reconcile !== undefined
      && (!supplied.reconcile || typeof supplied.reconcile !== "object"
          || Array.isArray(supplied.reconcile))) {
    throw new Error("Knowledge Base reconcile must map source keys to exact article IDs");
  }
  const options = {...supplied, reconcile: {...(supplied.reconcile || {})}};
  if (options.task !== undefined && (!options.task || typeof options.task !== "object"
      || Array.isArray(options.task) || typeof options.task.issueId !== "string")) {
    throw new Error("Knowledge Base task mode requires an Air task and issue ID");
  }
  if (!options.task && !options.dryRun && !/^[0-9a-f]{40}$/.test(options.candidateRevision || "")) {
    throw new Error("Knowledge Base publication requires a verified full candidateRevision SHA");
  }
  const root = options.root;
  const scripts = root.replace(/[\\/]+$/, "") + "/Scripts/";
  const helper = scripts + "youtrack_knowledge_base.py";
  const required = ["get_article"];
  if (!options.dryRun) required.push("create_article", "update_article");
  if (options.task) {
    required.push("get_issue", "get_issue_comments");
    if (!options.dryRun) required.push("add_issue_comment");
  }
  for (const method of required) {
    if (typeof tools["mcp__youtrack__" + method] !== "function") {
      throw new Error("Missing YouTrack connector capability: " + method);
    }
  }

  // Quote one complete POSIX-shell argument, preserving all source punctuation.
  function quote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'";
  }

  // Decode one connector response without exposing an untrusted error body.
  function decode(result, collection = false) {
    if (!result || result.isError || !Array.isArray(result.content)) {
      throw new Error("YouTrack article connector request failed");
    }
    // Connector article tools return one JSON text block; other block types are ignored.
    const blocks = result.content.filter(function textBlock(item) {
      return item && item.type === "text";
    });
    if (blocks.length !== 1) throw new Error("Unexpected YouTrack connector response shape");
    let decoded;
    try {
      decoded = JSON.parse(blocks[0].text);
    } catch (error) {
      throw new Error("YouTrack article connector returned invalid JSON");
    }
    if (!decoded || typeof decoded !== "object" || Array.isArray(decoded) !== collection) {
      throw new Error("YouTrack article connector returned an incomplete response");
    }
    return decoded;
  }

  // Wait for a local helper and parse its single JSON result after all output arrives.
  async function command(argumentsText, script = helper) {
    let result = await tools.exec_command({
      cmd: "python3 " + quote(script) + " " + argumentsText + " --root " + quote(root),
      workdir: root, login: false, max_output_tokens: 30000, yield_time_ms: 1000
    });
    let output = result.output || "";
    while (result.session_id) {
      result = await tools.write_stdin({
        session_id: result.session_id, chars: "", yield_time_ms: 1000,
        max_output_tokens: 30000
      });
      output += result.output || "";
    }
    if (result.exit_code !== 0) {
      throw new Error("Knowledge Base helper failed: " + output.trim().slice(0, 8000));
    }
    try {
      return JSON.parse(output);
    } catch (error) {
      throw new Error("Knowledge Base helper returned invalid or truncated JSON");
    }
  }

  // Transfer JSON in bounded, Unicode-safe chunks to an engine-owned private file.
  async function payloadFile(values, payload, script) {
    const initialized = await local("payload-init", values, undefined, script);
    if (typeof initialized.payload_file !== "string" || !initialized.payload_file) {
      throw new Error("Knowledge Base helper did not allocate a payload file");
    }
    let chunk = "";
    for (const character of JSON.stringify(payload)) {
      if (chunk.length + character.length > 8000) {
        await local("payload-append", {...values, payload_file: initialized.payload_file, chunk}, undefined, script);
        chunk = "";
      }
      chunk += character;
    }
    if (chunk) {
      await local("payload-append", {...values, payload_file: initialized.payload_file, chunk}, undefined, script);
    }
    return initialized.payload_file;
  }

  // Invoke one known helper operation with quoted flags and bounded payload transport.
  async function local(operation, values = {}, payload = undefined, script = helper) {
    let argumentsText = operation;
    for (const [key, value] of Object.entries(values)) {
      if (value === undefined || value === null || value === false) continue;
      const flag = " --" + key.replace(/_/g, "-");
      argumentsText += flag + (value === true ? "" : "=" + quote(value));
    }
    if (payload !== undefined) {
      const serialized = JSON.stringify(payload);
      if (serialized.length <= 4096) {
        argumentsText += " --payload=" + quote(serialized);
      } else {
        argumentsText += " --payload-file=" + quote(await payloadFile(values, payload, script));
      }
    }
    return await command(argumentsText, script);
  }

  // Read every article line and reject any revision change or nonprogressing page.
  async function full(articleId) {
    if (typeof articleId !== "string" || !articleId) {
      throw new Error("An exact YouTrack article ID is required");
    }
    let first;
    let offset = 0;
    let totalCharacters = 0;
    const parts = [];
    for (let pageNumber = 0; pageNumber < 10000; pageNumber++) {
      const page = decode(await tools.mcp__youtrack__get_article({
        articleId, linesOffset: offset, linesCount: 500
      }));
      const meta = page.contentMeta;
      if (page.id !== articleId || typeof page.content !== "string"
          || page.updatedAt === undefined || page.updatedAt === null
          || !meta || meta.linesOffset !== offset
          || !Number.isInteger(meta.linesCount) || meta.linesCount < 0 || meta.linesCount > 500
          || !Number.isInteger(meta.totalLines) || meta.totalLines < 0
          || offset + meta.linesCount > meta.totalLines
          || (meta.hasMoreLines ? offset + meta.linesCount >= meta.totalLines
            : offset + meta.linesCount !== meta.totalLines)
          || (page.content.split("\n").length !== meta.linesCount
            && !(page.content === "" && meta.linesCount === 0))
          || typeof meta.hasMoreLines !== "boolean") {
        throw new Error("Incomplete or nonprogressing paginated article read: " + articleId);
      }
      if (!first) first = page;
      if (page.id !== first.id || page.updatedAt !== first.updatedAt
          || meta.totalLines !== first.contentMeta.totalLines) {
        throw new Error("Article changed during paginated read: " + articleId);
      }
      totalCharacters += page.content.length;
      if (totalCharacters > 4 * 1024 * 1024) {
        throw new Error("Article exceeds the bounded synchronization read size: " + articleId);
      }
      parts.push(page.content);
      if (!meta.hasMoreLines) return {...first, content: parts.join("\n")};
      if (meta.linesCount === 0) {
        throw new Error("Nonprogressing paginated article read: " + articleId);
      }
      offset += meta.linesCount;
    }
    throw new Error("Too many pages while reading article: " + articleId);
  }

  // Normalize connector names while rejecting missing or structurally ambiguous access data.
  function names(values, users) {
    if (!Array.isArray(values)) return null;
    const result = [];
    for (const value of values) {
      const name = typeof value === "string" ? value : value && value[users ? "login" : "name"];
      if (typeof name !== "string" || !name || result.includes(name)) return null;
      result.push(name);
    }
    return result.sort();
  }

  // Compare access sets without depending on response ordering.
  function sameNames(actual, expected, users) {
    const left = names(actual, users);
    const right = names(expected, users);
    return left !== null && right !== null && JSON.stringify(left) === JSON.stringify(right);
  }

  // Verify the actual project, parent and visibility before adopting any created page.
  function assertScope(page, parentId, scope) {
    const project = typeof page.project === "string" ? page.project : page.project && page.project.shortName;
    const actualParent = page.parentArticle === null ? null : page.parentArticle && page.parentArticle.id;
    if (project !== scope.project || actualParent !== parentId
        || !sameNames(page.permittedGroups, scope.permitted_groups, false)
        || !sameNames(page.permittedUsers, scope.permitted_users, true)) {
      throw new Error("Article project, parent or visibility does not match the managed scope: " + page.id);
    }
  }

  // Require a complete, bounded issue comment scan to reconcile a backlink.
  async function issueComments(issueId) {
    const comments = [];
    const seen = new Set();
    for (let offset = 0; offset < 10000; offset += 10) {
      const page = decode(await tools.mcp__youtrack__get_issue_comments({issueId, offset, limit: 10}), true);
      if (page.length > 10) throw new Error("Unexpected YouTrack issue comment page size");
      for (const comment of page) {
        if (!comment || typeof comment.id !== "string" || seen.has(comment.id)) {
          throw new Error("Incomplete or nonprogressing YouTrack issue comment read");
        }
        comments.push(comment);
        seen.add(comment.id);
      }
      if (page.length < 10) return comments;
    }
    throw new Error("Too many issue comment pages to verify a unique task backlink");
  }

  // Use exact reported restrictions, falling back only to the verified limited library audience.
  function taskAudience(issue, scope) {
    if (issue.permittedGroups === null || issue.permittedUsers === null
        || (issue.permittedGroups === undefined && issue.permittedUsers === undefined)) {
      throw new Error("YouTrack issue visibility could not be confirmed");
    }
    const groups = names(issue.permittedGroups ?? [], false);
    const users = names(issue.permittedUsers ?? [], true);
    if (!groups || !users) throw new Error("YouTrack issue visibility could not be confirmed");
    if (groups.length || users.length) return {...scope, permitted_groups: groups, permitted_users: users};
    if (issue.permittedGroups === undefined || issue.permittedUsers === undefined) {
      throw new Error("YouTrack issue visibility could not be confirmed");
    }
    if (!scope.permitted_groups.length && !scope.permitted_users.length) {
      throw new Error("Task publication requires a verified limited issue or Project History audience");
    }
    return scope;
  }

  // Publish only committed task content, replacing one owned Markdown block at the same URL.
  async function publishTask() {
    const task = options.task;
    const issueId = task.issueId;
    const script = scripts + "youtrack_kb_task.py";
    const prepared = await local("prepare", {issue: issueId}, task, script);
    const {scope, history, identity, marker} = prepared;
    const articleBase = history.url.slice(0, history.url.lastIndexOf("/") + 1);
    const issueUrl = articleBase.replace(/articles\/$/, "") + "issue/" + issueId;
    const opening = "<!-- air-task-kb:" + marker + ":start -->";
    const closing = "<!-- air-task-kb:" + marker + ":end -->";
    const backlinkMarker = "<!-- air-task-kb:" + marker + ":backlink -->";
    const placeholderTitle = "Preparing task documentation " + marker.slice(0, 16);
    const placeholder = "Task documentation is being prepared.\n\n<!-- air-task-kb:" + marker + ":pending -->\n";
    const owned = opening + "\n\n[YouTrack issue " + issueId + "](" + issueUrl + ")\n\n"
      + "**Stage** " + prepared.stage + "\n\n**Checkpoint** `" + prepared.candidate + "`\n\n"
      + prepared.progress.trim() + "\n\n## Approved plan\n\n**Reviewed commit** `"
      + prepared.approved + "`\n\n" + prepared.plan.trimEnd() + "\n\n" + closing;
    let receipt = prepared.receipt;

    // Read the canonical issue again before every external mutation or reconciliation.
    async function readIssue() {
      const issue = decode(await tools.mcp__youtrack__get_issue({issueId}));
      const key = issue.idReadable || issue.id;
      const project = typeof issue.project === "string" ? issue.project : issue.project?.shortName;
      if (key !== issueId || project !== scope.project || issue.isDraft !== false || issue.url !== issueUrl) {
        throw new Error("YouTrack issue identity differs from this Air task");
      }
      return {issue, audience: taskAudience(issue, scope)};
    }

    // Verify a fresh scope and the exact same canonical article origin before editing.
    async function readScope(expected) {
      const parent = await full(history.id);
      assertScope(parent, null, scope);
      if (parent.url !== history.url || parent.summary !== history.summary || !Array.isArray(parent.childArticles)) {
        throw new Error("Verified Project History article or child list could not be confirmed");
      }
      const {issue, audience} = await readIssue();
      if (expected && (!sameNames(expected.permitted_groups, audience.permitted_groups, false)
          || !sameNames(expected.permitted_users, audience.permitted_users, true))) {
        throw new Error("YouTrack task audience changed during publication");
      }
      return {parent, issue, audience};
    }

    // Scope every publication to the persisted task identity and current audience.
    function verifyArticle(page, audience) {
      assertScope(page, history.id, audience);
      if (!page.id.startsWith(scope.project + "-A-") || page.url !== articleBase + page.id
          || (receipt.article_url && receipt.article_url !== page.url)) {
        throw new Error("Task article URL differs from the verified project destination");
      }
    }

    // Commit a compact task journal through the existing private payload transport.
    async function recordTask(operation, details = {}) {
      receipt = await local("record", {issue: issueId}, {identity, operation, ...details}, script);
    }

    // Return one child only when its marker is verified against the pending create intent.
    async function recoverCreate(parent, target, audience) {
      const pending = parent.childArticles.filter(child => child?.summary === target.summary);
      const exact = task.reconcileArticleId;
      if (pending.length > 1 || (exact && pending.length && pending[0].id !== exact)) {
        throw new Error("Conflicting YouTrack task article candidates require operator reconciliation");
      }
      const identifier = exact || pending[0]?.id;
      if (!identifier) throw new Error("Task creation remains pending; provide the exact reconcileArticleId");
      const page = await full(identifier);
      verifyArticle(page, audience);
      return page;
    }

    // Verify exact content and managed metadata before advancing a pending task journal.
    async function verified(page, target, audience) {
      verifyArticle(page, audience);
      if (page.summary !== target.summary || page.content !== target.content) {
        throw new Error("Task article differs from the pending write; reconcile its current revision");
      }
      await recordTask("article-verified", {actual: {id: page.id, url: page.url, content: page.content}});
    }

    // Send one content update without replacing a human title unless activating a new placeholder.
    async function updateTask(page, target) {
      decode(await tools.mcp__youtrack__update_article({articleId: page.id,
        ...(target.summary === page.summary ? {} : {summary: target.summary}), content: target.content}));
      return await full(page.id);
    }

    const {parent, issue, audience} = await readScope();
    const reconcile = task.reconcileArticleId;
    if (reconcile !== undefined && (typeof reconcile !== "string"
        || !/^[A-Z][A-Z0-9_-]*-A-[1-9][0-9]*$/.test(reconcile)
        || receipt.article_intent?.kind !== "create")) {
      throw new Error("reconcileArticleId is valid only for an existing pending task creation");
    }
    if (options.dryRun) {
      text({complete: false, dryRun: true, issueId, issueUrl, articleId: receipt.article_id || null,
        candidateCommit: prepared.candidate, pending: Boolean(receipt.article_intent || receipt.active_backlink)});
      return;
    }
    // Recover an ambiguous response only by observing the exact intended result.
    if (receipt.article_intent) {
      const target = receipt.article_intent;
      let page = target.kind === "create" ? await recoverCreate(parent, target, audience)
        : await full(receipt.article_id);
      if (target.kind === "update" && target.candidate === prepared.candidate
          && page.updatedAt === target.previousUpdatedAt && page.summary === target.previousSummary
          && page.content === target.content.replace(target.owned, () => receipt.owned)) {
        await readScope(audience);
        const latest = await full(page.id);
        verifyArticle(latest, audience);
        if (latest.updatedAt === page.updatedAt && latest.content === page.content && latest.summary === page.summary) {
          page = await updateTask(latest, target);
        } else {
          page = latest;
        }
      }
      await verified(page, target, audience);
    }
    if (!receipt.article_id) {
      const markerExists = (await issueComments(issueId)).some(comment => !comment.deleted
        && typeof comment.text === "string" && comment.text.includes(backlinkMarker));
      if (markerExists) throw new Error("The issue already has a task backlink; restore its verified local receipt");
      const latestScope = await readScope(audience);
      const existing = latestScope.parent.childArticles.find(child => child?.summary === placeholderTitle
        || (typeof child?.summary === "string" && child.summary.startsWith(issueId)
          && !/^[A-Za-z0-9_-]/.test(child.summary.slice(issueId.length))));
      if (existing) throw new Error("A task article already exists without a verified local receipt: " + existing.id);
      const target = {kind: "create", content: placeholder, owned: placeholder, summary: placeholderTitle,
        candidate: null, approved: null};
      await recordTask("article-intent", {target});
      const created = decode(await tools.mcp__youtrack__create_article({project: scope.project,
        summary: target.summary, content: target.content, parentArticle: history.id,
        permittedGroups: audience.permitted_groups, permittedUsers: audience.permitted_users}));
      await verified(await full(created.id), target, audience);
    }

    // Preserve the human article title and all text outside the untouched managed block.
    if (!receipt.active_backlink) {
      const page = await full(receipt.article_id);
      verifyArticle(page, audience);
      const previous = receipt.owned;
      if (!previous || page.content.indexOf(previous) < 0 || page.content.indexOf(previous) !== page.content.lastIndexOf(previous)
          || (previous === placeholder && page.content !== placeholder)) {
        throw new Error("Task article managed content has changed outside Air; preserve the owner's edits");
      }
      if (owned !== previous) {
        if (receipt.candidate === prepared.candidate) {
          throw new Error("Changed task progress requires a new committed checkpoint");
        }
        const title = typeof issue.summary === "string" ? issue.summary.replace(/[\u0000-\u001f\u007f]/g, " ").trim() : "";
        const target = {kind: "update", content: page.content.replace(previous, () => owned), owned,
          summary: previous === placeholder && page.summary === placeholderTitle
            ? (issueId + (title ? " · " + title.slice(0, 200) : "")) : page.summary,
          previousUpdatedAt: page.updatedAt, previousSummary: page.summary,
          candidate: prepared.candidate, approved: prepared.approved, run: prepared.run, stage: prepared.stage};
        await readScope(audience);
        const latest = await full(page.id);
        verifyArticle(latest, audience);
        if (latest.updatedAt !== page.updatedAt || latest.content !== page.content || latest.summary !== page.summary) {
          throw new Error("Task article changed before publication; preserve the owner's edits");
        }
        await recordTask("article-intent", {target});
        await verified(await updateTask(page, target), target, audience);
      }
    }

    // Add one restricted, read-back-verified backlink while preserving the issue description.
    const backlink = "[Approved plan and task progress](" + receipt.article_url + ")\n\n" + backlinkMarker;
    async function findBacklink() {
      const matches = (await issueComments(issueId)).filter(comment => !comment.deleted
        && typeof comment.text === "string" && comment.text.includes(backlinkMarker));
      if (matches.length > 1 || (matches[0] && (matches[0].text !== backlink
          || matches[0].permittedGroups === null || matches[0].permittedUsers === null
          || !sameNames(matches[0].permittedGroups ?? [], audience.permitted_groups, false)
          || !sameNames(matches[0].permittedUsers ?? [], audience.permitted_users, true)))) {
        throw new Error("Issue backlink content or visibility differs from the task receipt");
      }
      return matches[0];
    }
    await readScope(audience);
    const taskPage = await full(receipt.article_id);
    verifyArticle(taskPage, audience);
    if (!taskPage.content.includes(receipt.owned)) throw new Error("Task article changed before issue backlink publication");
    let comment = await findBacklink();
    if (!comment) {
      if (receipt.active_backlink || receipt.backlink_id) {
        throw new Error("Task backlink remains pending or changed on YouTrack; reconcile it before retrying");
      }
      await readScope(audience);
      await recordTask("backlink-intent");
      decode(await tools.mcp__youtrack__add_issue_comment({issueId, text: backlink,
        permittedGroups: audience.permitted_groups, permittedUsers: audience.permitted_users}));
      comment = await findBacklink();
      if (!comment) throw new Error("Could not verify the YouTrack issue backlink");
    }
    if (receipt.backlink_id !== comment.id) await recordTask("backlink-verified", {actual: comment.id});
    const complete = receipt.candidate === prepared.candidate && receipt.owned === owned;
    text({complete, issueId, issueUrl, articleId: receipt.article_id, articleUrl: receipt.article_url, backlinkId: comment.id,
      candidateCommit: receipt.candidate, ...(complete ? {} : {pending: "Reinvoke after the recovered backlink receipt"})});
  }

  // Read the complete checkpoint catalog and preserve its parent-first ordering.
  async function loadPlan(run) {
    const result = {articles: [], mapping: {}};
    let offset = 0;
    let expectedTotal;
    do {
      const page = await local("catalog", {run, offset, limit: 50});
      if (!Array.isArray(page.articles) || !Number.isInteger(page.total)
          || page.total < 0 || (expectedTotal !== undefined && page.total !== expectedTotal)
          || (!page.articles.length && offset < page.total)) {
        throw new Error("Knowledge Base catalog changed or failed to advance");
      }
      expectedTotal = page.total;
      for (const article of page.articles) {
        if (!article || typeof article.key !== "string" || !article.key
            || typeof article.summary !== "string" || !article.summary
            || !(article.parent === null || typeof article.parent === "string")
            || result.articles.some(function duplicate(existing) { return existing.key === article.key; })) {
          throw new Error("Knowledge Base catalog contains a duplicate or invalid source key");
        }
        result.articles.push(article);
        if (article.id) result.mapping[article.key] = article.id;
      }
      offset += page.articles.length;
    } while (offset < expectedTotal);
    if (offset !== expectedTotal) throw new Error("Knowledge Base catalog size does not match its snapshot");
    return result;
  }

  // Recognize the lock acknowledgement without depending on JSON whitespace.
  function acquired(output) {
    for (const line of String(output || "").split("\n")) {
      try {
        if (JSON.parse(line).locked === true) return true;
      } catch (error) {
        // Terminal startup text is not a lock acknowledgement.
      }
    }
    return false;
  }

  let lock;
  let run;
  let failure;
  try {
    lock = await tools.exec_command({
      cmd: "python3 " + quote(helper) + " lock --root " + quote(root),
      workdir: root, login: false, tty: true, yield_time_ms: 1000, max_output_tokens: 1000
    });
    let lockOutput = lock.output || "";
    for (let attempts = 0; lock.session_id && !acquired(lockOutput) && attempts < 30; attempts++) {
      lock = await tools.write_stdin({
        session_id: lock.session_id, chars: "", yield_time_ms: 1000, max_output_tokens: 1000
      });
      lockOutput += lock.output || "";
    }
    if (!lock.session_id || !acquired(lockOutput)) {
      throw new Error("Could not acquire the repository Knowledge Base coordinator lock");
    }
    if (options.task) {
      await publishTask();
      return;
    }
    const prepared = await local("prepare");
    run = prepared.run;
    if (typeof run !== "string" || !run) throw new Error("Knowledge Base helper returned no snapshot");
    // All sources, page sizes and links are validated before any article write.
    const rendered = await local("render", {run});
    if (!options.dryRun && (prepared.revision !== options.candidateRevision
        || prepared.working_copy_sources !== 0 || prepared.working_copy_configuration !== 0
        || rendered.link_warnings.length !== 0)) {
      throw new Error("Publish the validated committed revision with zero Knowledge Base link warnings");
    }
    let plan = await loadPlan(run);
    const rootArticle = plan.articles.find(function managedRoot(article) { return article.key === "group:root"; });
    if (!rootArticle) throw new Error("Knowledge Base catalog has no managed root");
    if (!rootArticle.id && !rootArticle.intent && !options.bootstrap) {
      const checked = await local("finish", {run, dry_run: true});
      text({...checked, dryRun: !!options.dryRun, complete: false,
        requiresBootstrap: true, pending_count: plan.articles.length,
        wouldCreate: plan.articles.length,
        reason: "No managed library receipt; explicitly authorize bootstrap or restore its existing receipts"});
      return;
    }
    // Existing ancestors must retain their verified tree and access before new descendants exist.
    if (rootArticle.id) {
      const articleBase = prepared.root_url.slice(0, prepared.root_url.lastIndexOf("/") + 1);
      for (const article of plan.articles) {
        if (!plan.mapping[article.key]) continue;
        const parent = article.parent === null ? null : plan.mapping[article.parent];
        if (parent === undefined) {
          throw new Error("Mapped article has no verified parent: " + article.key);
        }
        const existing = await full(plan.mapping[article.key]);
        assertScope(existing, parent, prepared);
        const expectedUrl = article.key === "group:root" ? prepared.root_url : articleBase + existing.id;
        if (existing.url !== expectedUrl) {
          throw new Error("Article URL differs from its verified destination receipt: " + existing.id);
        }
      }
    }
    if (typeof notify === "function") notify({stage: "snapshot", ...prepared, dryRun: !!options.dryRun});
    const report = {unchanged: 0, wouldCreate: 0, wouldUpdate: 0, created: 0, verified: 0, conflicts: []};

    // Create parent pages first, recording a durable intent before each connector call.
    for (const article of plan.articles) {
      if (plan.mapping[article.key]) continue;
      if (options.dryRun) {
        report.wouldCreate++;
        continue;
      }
      const parent = article.parent === null ? null : plan.mapping[article.parent];
      if (parent === undefined) throw new Error("Cannot create without a verified parent: " + article.key);
      let intent = article.intent;
      let response;
      let page;
      let recovered = false;
      if (intent) {
        const exactId = article.key === "group:root"
          ? options.reconcileRoot || options.reconcile[article.key] : options.reconcile[article.key];
        if (typeof exactId !== "string" || !exactId) {
          throw new Error("Uncertain article creation remains fenced for " + article.key
            + "; supply reconcileRoot or reconcile[key] with the exact created article ID");
        }
        page = await full(exactId);
        recovered = true;
      } else {
        const marker = "youtrack-kb-sync:" + run.split(/[\\/]/).pop() + ":" + article.key;
        const placeholder = "Documentation synchronization is in progress.\n\nSync identity: `" + marker + "`\n";
        intent = {operation: "intent", key: article.key, placeholder, marker};
        await local("record", {run}, intent);
        response = decode(await tools.mcp__youtrack__create_article({
          project: prepared.project, summary: article.summary, content: placeholder,
          ...(parent === null ? {} : {parentArticle: parent}),
          permittedGroups: prepared.permitted_groups, permittedUsers: prepared.permitted_users
        }));
        page = await full(response.id);
      }
      assertScope(page, parent, prepared);
      if (page.summary !== article.summary || page.content !== intent.placeholder) {
        throw new Error("Created article does not match its durable placeholder intent: " + page.id);
      }
      await local("record", {run}, {operation: "created", key: article.key,
        id: page.id, url: (response && response.url) || page.url, recovered});
      plan.mapping[article.key] = page.id;
      report.created++;
    }

    // Render final article URLs after all verified IDs exist, then publish leaves first.
    await local("render", {run});
    plan = await loadPlan(run);
    const articles = [...plan.articles].reverse();
    let checked = 0;
    for (const article of articles) {
      if (!plan.mapping[article.key]) continue;
      let remote = await full(plan.mapping[article.key]);
      let decision = await local("assess", {run}, {key: article.key, remote});
      checked++;
      if (decision.action === "conflict") {
        report.conflicts.push({key: article.key, id: remote.id, reason: decision.reason});
        if (!options.dryRun) {
          await local("record", {run}, {operation: "result", key: article.key,
            status: "conflict", reason: decision.reason});
        }
      } else if (decision.action === "unchanged") {
        report.unchanged++;
        if (!options.dryRun) {
          await local("record", {run}, {operation: "result", key: article.key,
            status: "unchanged", id: remote.id});
        }
      } else if (decision.action !== "update") {
        throw new Error("Unknown Knowledge Base synchronization decision");
      } else if (options.dryRun) {
        report.wouldUpdate++;
      } else {
        // Recheck immediately before replacement; MCP provides no atomic revision lock.
        remote = await full(remote.id);
        decision = await local("assess", {run}, {key: article.key, remote});
        if (decision.action === "conflict") {
          report.conflicts.push({key: article.key, id: remote.id, reason: decision.reason});
          await local("record", {run}, {operation: "result", key: article.key,
            status: "conflict", reason: decision.reason});
          continue;
        }
        if (decision.action === "update") {
          await local("record", {run}, {operation: "update_intent", key: article.key,
            status: "pending", id: remote.id, content_sha256: decision.content_sha256});
          decode(await tools.mcp__youtrack__update_article({articleId: remote.id,
            summary: decision.summary, content: decision.content}));
        } else if (decision.action !== "unchanged") {
          throw new Error("Unknown Knowledge Base synchronization recheck decision");
        }
        const verifiedRemote = await full(remote.id);
        const verified = await local("assess", {run}, {key: article.key, remote: verifiedRemote});
        if (verified.action !== "unchanged") {
          throw new Error("Article publication read-back did not match: " + remote.id);
        }
        await local("record", {run}, {operation: "result", key: article.key,
          status: "verified", id: remote.id});
        report.verified++;
      }
      if (checked % 25 === 0 && typeof notify === "function") {
        notify({stage: "verify", checked, total: articles.length, ...report});
      }
    }
    const finished = await local("finish", {run, dry_run: !!options.dryRun});
    text({...finished, ...report, dryRun: !!options.dryRun, checked, total: articles.length, run});
  } catch (error) {
    failure = error;
    throw error;
  } finally {
    // Release only this invocation's coordinator process, including failed or preview runs.
    if (lock && lock.session_id) {
      try {
        await tools.write_stdin({session_id: lock.session_id, chars: "release\n",
          yield_time_ms: 1000, max_output_tokens: 1000});
      } catch (error) {
        if (!failure) throw error;
      }
    }
  }
})()
