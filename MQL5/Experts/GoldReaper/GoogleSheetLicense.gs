/**
 * Google Sheet license endpoint for The Gold Reaper v4.6.
 *
 * Bind this script to the spreadsheet that contains a "Licenses" tab and
 * deploy it as a Web app (execute as the owner, access: Anyone).
 *
 * When a new MT5 account contacts the endpoint, the script appends it with
 * Active=false and records its account/terminal telemetry. The EA stays
 * hidden until the owner changes Active to TRUE.
 */
const LICENSE_SHEET_NAME = 'Licenses';
const TRADE_HISTORY_SHEET_NAME = 'TradeHistory';
const DAILY_PROFIT_SHEET_NAME = 'DailyProfit';
const DASHBOARD_SHEET_NAME = 'Dashboard';
const LICENSE_HEADERS = [
  'Name',
  'Account',
  'Active',
  'ExpiryUTC',
  'AllowedServer',
  'Product',
  'AccountName',
  'Broker',
  'DetectedServer',
  'Currency',
  'Balance',
  'Equity',
  'Leverage',
  'TradeMode',
  'Symbol',
  'Terminal',
  'TerminalBuild',
  'FirstSeenUTC',
  'LastSeenUTC',
  'LastResult',
  'FloatingProfit',
  'Credit',
  'Margin',
  'FreeMargin',
  'MarginLevel',
  'OpenPositions',
  'PendingOrders',
  'HistorySync',
];
const TRADE_HISTORY_HEADERS = [
  'Account',
  'TimeUTC',
  'DealTicket',
  'OrderTicket',
  'Symbol',
  'Type',
  'Entry',
  'Volume',
  'Price',
  'Profit',
  'Commission',
  'Swap',
  'Fee',
  'NetProfit',
  'PositionID',
  'Magic',
  'Reason',
  'Comment',
  'ExternalID',
  'ReceivedUTC',
];

function doGet(e) {
  const params = (e && e.parameter) || {};
  const account = clean_(params.account);
  const server = clean_(params.server);
  const product = clean_(params.product);

  try {
    const expectedKey = PropertiesService.getScriptProperties()
      .getProperty('LICENSE_API_KEY') || '';
    if (expectedKey && clean_(params.key) !== expectedKey) {
      return text_('DENIED|invalid_key');
    }
    if (!/^\d+$/.test(account)) {
      return text_('DENIED|invalid_account');
    }

    const lock = LockService.getScriptLock();
    if (!lock.tryLock(5000)) {
      return text_('ERROR|busy');
    }

    try {
      const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
      const sheet = spreadsheet.getSheetByName(LICENSE_SHEET_NAME);
      if (!sheet) {
        return text_('ERROR|missing_licenses_sheet');
      }

      ensureSchema_(sheet);
      const rows = sheet.getDataRange().getValues();
      const columns = mapColumns_(rows[0]);
      if (columns.account < 0 || columns.active < 0) {
        return text_('ERROR|missing_account_or_active_column');
      }

      let firstAccountRow = -1;
      let matchingRow = -1;
      for (let i = 1; i < rows.length; i += 1) {
        const row = rows[i];
        if (clean_(row[columns.account]) !== account) continue;
        if (firstAccountRow < 0) firstAccountRow = i;
        if (!scopeMatches_(cell_(row, columns.allowedServer), server)) continue;
        if (!scopeMatches_(cell_(row, columns.product), product)) continue;
        matchingRow = i;
        break;
      }

      if (firstAccountRow < 0) {
        appendPendingAccount_(sheet, columns, params);
        return text_('DENIED|pending_approval');
      }

      if (matchingRow < 0) {
        writeTelemetry_(sheet, firstAccountRow + 1, rows[firstAccountRow],
          columns, params, 'DENIED: SCOPE');
        return text_('DENIED|server_or_product_not_allowed');
      }

      const row = rows[matchingRow];
      if (!isActive_(cell_(row, columns.active))) {
        writeTelemetry_(sheet, matchingRow + 1, row, columns, params,
          'DENIED: INACTIVE');
        return text_('DENIED|license_inactive');
      }

      const expiry = expiryUnix_(cell_(row, columns.expiry));
      if (expiry === null) {
        writeTelemetry_(sheet, matchingRow + 1, row, columns, params,
          'ERROR: EXPIRY');
        return text_('ERROR|invalid_expiry');
      }
      if (expiry > 0 && Math.floor(Date.now() / 1000) >= expiry) {
        writeTelemetry_(sheet, matchingRow + 1, row, columns, params,
          'DENIED: EXPIRED');
        return text_('DENIED|license_expired');
      }

      writeTelemetry_(sheet, matchingRow + 1, row, columns, params,
        'APPROVED');
      const displayName = safeField_(
        cell_(row, columns.name) || clean_(params.account_name));
      return text_('OK|' + expiry + '|' + displayName);
    } finally {
      lock.releaseLock();
    }
  } catch (error) {
    console.error(error);
    return text_('ERROR|server_error');
  }
}

/**
 * Receives full MT5 deal history in small, retry-safe batches.
 * The same account/deal pair is stored only once.
 */
function doPost(e) {
  const params = (e && e.parameter) || {};
  const account = clean_(params.account);
  const server = clean_(params.server);
  const product = clean_(params.product);

  try {
    if (clean_(params.action).toLowerCase() !== 'deals') {
      return text_('DENIED|invalid_action');
    }
    const expectedKey = PropertiesService.getScriptProperties()
      .getProperty('LICENSE_API_KEY') || '';
    if (expectedKey && clean_(params.key) !== expectedKey) {
      return text_('DENIED|invalid_key');
    }
    if (!/^\d+$/.test(account)) {
      return text_('DENIED|invalid_account');
    }

    const lock = LockService.getScriptLock();
    if (!lock.tryLock(10000)) return text_('ERROR|busy');

    try {
      const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
      const licenses = spreadsheet.getSheetByName(LICENSE_SHEET_NAME);
      if (!licenses) return text_('ERROR|missing_licenses_sheet');

      ensureSchema_(licenses);
      const rows = licenses.getDataRange().getValues();
      const columns = mapColumns_(rows[0]);
      const match = findMatchingAccount_(rows, columns, account, server, product);
      if (match < 1) return text_('DENIED|account_not_authorized');

      const licenseRow = rows[match];
      if (!isActive_(cell_(licenseRow, columns.active))) {
        return text_('DENIED|license_inactive');
      }
      const expiry = expiryUnix_(cell_(licenseRow, columns.expiry));
      if (expiry === null) return text_('ERROR|invalid_expiry');
      if (expiry > 0 && Math.floor(Date.now() / 1000) >= expiry) {
        return text_('DENIED|license_expired');
      }

      const history = ensureTradeHistorySheet_(spreadsheet);
      const rawPayload = params.payload === null || params.payload === undefined ?
        '' : String(params.payload);
      const records = parseDealPayload_(rawPayload, account);
      const inserted = appendUniqueDeals_(history, records);
      ensureDailyProfitSheet_(spreadsheet, history);
      writeHistorySync_(licenses, match + 1, columns,
        'SYNCING · +' + inserted + ' deals');
      return text_('OK|' + inserted);
    } finally {
      lock.releaseLock();
    }
  } catch (error) {
    console.error(error);
    return text_('ERROR|server_error');
  }
}

function findMatchingAccount_(rows, columns, account, server, product) {
  if (columns.account < 0 || columns.active < 0) return -1;
  for (let i = 1; i < rows.length; i += 1) {
    const row = rows[i];
    if (clean_(row[columns.account]) !== account) continue;
    if (!scopeMatches_(cell_(row, columns.allowedServer), server)) continue;
    if (!scopeMatches_(cell_(row, columns.product), product)) continue;
    return i;
  }
  return -1;
}

function ensureTradeHistorySheet_(spreadsheet) {
  let sheet = spreadsheet.getSheetByName(TRADE_HISTORY_SHEET_NAME);
  if (!sheet) sheet = spreadsheet.insertSheet(TRADE_HISTORY_SHEET_NAME);

  if (sheet.getLastRow() === 0 || sheet.getLastColumn() === 0) {
    sheet.getRange(1, 1, 1, TRADE_HISTORY_HEADERS.length)
      .setValues([TRADE_HISTORY_HEADERS]);
  } else {
    const existing = sheet.getRange(1, 1, 1, sheet.getLastColumn())
      .getValues()[0].map(normalizeHeader_);
    const missing = TRADE_HISTORY_HEADERS.filter(function (header) {
      return !existing.includes(normalizeHeader_(header));
    });
    if (missing.length > 0) {
      sheet.getRange(1, sheet.getLastColumn() + 1, 1, missing.length)
        .setValues([missing]);
    }
  }
  return sheet;
}


function ensureDailyProfitSheet_(spreadsheet, history) {
  let sheet = spreadsheet.getSheetByName(DAILY_PROFIT_SHEET_NAME);
  const created = !sheet;
  if (!sheet) sheet = spreadsheet.insertSheet(DAILY_PROFIT_SHEET_NAME, 1);

  if (sheet.getMaxColumns() < 3) {
    sheet.insertColumnsAfter(sheet.getMaxColumns(), 3 - sheet.getMaxColumns());
  }

  const source = history || ensureTradeHistorySheet_(spreadsheet);
  const requiredRows = Math.max(source.getMaxRows(), 2);
  if (sheet.getMaxRows() < requiredRows) {
    const firstNewRow = sheet.getMaxRows() + 1;
    const rowsToAdd = requiredRows - sheet.getMaxRows();
    sheet.insertRowsAfter(sheet.getMaxRows(), rowsToAdd);
    formatDailyProfitDataRows_(sheet, firstNewRow, rowsToAdd);
  }

  const formulaCell = sheet.getRange('A1');
  if (!formulaCell.getFormula()) {
    const lastRow = sheet.getLastRow();
    if (lastRow > 0) {
      sheet.getRange(1, 1, lastRow, Math.min(sheet.getLastColumn(), 3))
        .clearContent();
    }
    setDailyProfitFormula_(formulaCell);
  }

  if (created) {
    formatDailyProfitSheet_(sheet);
    configureDashboardWidth_(spreadsheet);
  }
  return sheet;
}

function dailyProfitFormula_(separator) {
  return '=IF(' +
    'COUNTIF(TradeHistory!F2:F' + separator + '"BUY")+' +
    'COUNTIF(TradeHistory!F2:F' + separator + '"SELL")=0' + separator +
    'HSTACK("Date UTC"' + separator + '"Account"' + separator +
      '"Net P/L")' + separator +
    'QUERY(HSTACK(' +
      'IF(TradeHistory!B2:B=""' + separator + '""' + separator +
        'INT(TradeHistory!B2:B))' + separator +
      'TradeHistory!A2:A' + separator +
      'TradeHistory!N2:N' + separator +
      'TradeHistory!F2:F)' + separator +
      "\"select Col1,Col2,sum(Col3) where Col1 is not null and " +
        "(Col4 = 'BUY' or Col4 = 'SELL') group by Col1,Col2 " +
        "order by Col1 desc,Col2 label Col1 'Date UTC'," +
        "Col2 'Account',sum(Col3) 'Net P/L'\"" + separator +
      '0))';
}

function setDailyProfitFormula_(cell) {
  try {
    cell.setFormula(dailyProfitFormula_(','));
  } catch (error) {
    cell.setFormula(dailyProfitFormula_(';'));
  }
}

function formatDailyProfitDataRows_(sheet, firstRow, rowCount) {
  if (rowCount <= 0) return;
  sheet.getRange(firstRow, 1, rowCount, 3)
    .setFontFamily('Carlito')
    .setFontSize(11)
    .setVerticalAlignment('middle');
  sheet.getRange(firstRow, 1, rowCount, 1)
    .setNumberFormat('yyyy-mm-dd')
    .setHorizontalAlignment('center');
  sheet.getRange(firstRow, 2, rowCount, 1)
    .setHorizontalAlignment('center');
  sheet.getRange(firstRow, 3, rowCount, 1)
    .setNumberFormat('#,##0.00;[Red]-#,##0.00')
    .setHorizontalAlignment('right');
  sheet.setRowHeights(firstRow, rowCount, 26);
}

function formatDailyProfitSheet_(sheet) {
  sheet.setFrozenRows(1);
  sheet.setHiddenGridlines(true);
  sheet.setTabColor('#d4af37');
  sheet.getRange('A1:C1')
    .setBackground('#16181d')
    .setFontColor('#d4af37')
    .setFontWeight('bold')
    .setFontFamily('Carlito')
    .setFontSize(11)
    .setHorizontalAlignment('center')
    .setVerticalAlignment('middle')
    .setWrap(true);
  sheet.setRowHeight(1, 38);
  sheet.setColumnWidth(1, 130);
  sheet.setColumnWidth(2, 120);
  sheet.setColumnWidth(3, 150);
  formatDailyProfitDataRows_(sheet, 2, Math.max(sheet.getMaxRows() - 1, 1));

  const profitRange = sheet.getRange(
    2, 3, Math.max(sheet.getMaxRows() - 1, 1), 1);
  const rules = [
    SpreadsheetApp.newConditionalFormatRule()
      .whenNumberGreaterThan(0)
      .setFontColor('#127333')
      .setBold(true)
      .setRanges([profitRange])
      .build(),
    SpreadsheetApp.newConditionalFormatRule()
      .whenNumberLessThan(0)
      .setFontColor('#a50e0e')
      .setBold(true)
      .setRanges([profitRange])
      .build(),
  ];
  sheet.setConditionalFormatRules(rules);
}

function configureDashboardWidth_(spreadsheet) {
  const dashboard = spreadsheet.getSheetByName(DASHBOARD_SHEET_NAME);
  if (!dashboard) return;
  [208, 128, 156, 270].forEach(function (width, index) {
    dashboard.setColumnWidth(index + 1, width);
  });
}

function parseDealPayload_(payload, account) {
  if (!payload) return [];
  const records = [];
  payload.split(/\r?\n/).slice(0, 100).forEach(function (line) {
    if (!line) return;
    const values = line.split('\t');
    if (values.length < 16) return;

    const timeMilliseconds = Number(values[0]);
    const dealTicket = clean_(values[1]);
    if (!Number.isFinite(timeMilliseconds) || timeMilliseconds <= 0 ||
        !/^\d+$/.test(dealTicket)) return;

    const profit = numberOrZero_(values[8]);
    const commission = numberOrZero_(values[9]);
    const swap = numberOrZero_(values[10]);
    const fee = numberOrZero_(values[11]);
    records.push([
      account,
      new Date(timeMilliseconds),
      dealTicket,
      clean_(values[2]),
      clean_(values[3]),
      clean_(values[4]),
      clean_(values[5]),
      numberOrBlank_(values[6]),
      numberOrBlank_(values[7]),
      profit,
      commission,
      swap,
      fee,
      profit + commission + swap + fee,
      clean_(values[12]),
      integerOrBlank_(values[13]),
      clean_(values[15]),
      clean_(values[14]),
      clean_(values[16] || ''),
      new Date(),
    ]);
  });
  return records;
}

function appendUniqueDeals_(sheet, records) {
  if (records.length === 0) return 0;
  const existing = new Set();
  const lastRow = sheet.getLastRow();
  if (lastRow > 1) {
    sheet.getRange(2, 1, lastRow - 1, 3).getValues().forEach(function (row) {
      const account = clean_(row[0]);
      const ticket = clean_(row[2]);
      if (account && ticket) existing.add(account + '|' + ticket);
    });
  }

  const unique = [];
  records.forEach(function (record) {
    const key = clean_(record[0]) + '|' + clean_(record[2]);
    if (existing.has(key)) return;
    existing.add(key);
    unique.push(record);
  });
  if (unique.length > 0) {
    const requiredRows = sheet.getLastRow() + unique.length;
    if (requiredRows > sheet.getMaxRows()) {
      sheet.insertRowsAfter(sheet.getMaxRows(),
        requiredRows - sheet.getMaxRows());
    }
    sheet.getRange(sheet.getLastRow() + 1, 1, unique.length,
      TRADE_HISTORY_HEADERS.length).setValues(unique);
  }
  return unique.length;
}

function writeHistorySync_(sheet, rowNumber, columns, status) {
  if (columns.historySync < 0) return;
  sheet.getRange(rowNumber, columns.historySync + 1).setValue(status);
}

function ensureSchema_(sheet) {
  if (sheet.getLastRow() === 0 || sheet.getLastColumn() === 0) {
    sheet.getRange(1, 1, 1, LICENSE_HEADERS.length)
      .setValues([LICENSE_HEADERS]);
    return;
  }

  const lastColumn = sheet.getLastColumn();
  const headers = sheet.getRange(1, 1, 1, lastColumn).getValues()[0];
  const normalized = headers.map(normalizeHeader_);
  const missing = [];
  LICENSE_HEADERS.slice(6).forEach(function (header) {
    if (!normalized.includes(normalizeHeader_(header))) missing.push(header);
  });
  if (missing.length > 0) {
    sheet.getRange(1, lastColumn + 1, 1, missing.length)
      .setValues([missing]);
  }
}

function appendPendingAccount_(sheet, columns, params) {
  const now = new Date();
  const row = new Array(sheet.getLastColumn()).fill('');
  setCell_(row, columns.account, clean_(params.account));
  setCell_(row, columns.active, false);
  setCell_(row, columns.expiry, '');
  setCell_(row, columns.name, clean_(params.account_name));
  setCell_(row, columns.allowedServer, clean_(params.server) || '*');
  setCell_(row, columns.product, clean_(params.product));
  setTelemetryValues_(row, columns, params, now, now, 'WAITING APPROVAL');
  sheet.appendRow(row);
}

function writeTelemetry_(sheet, rowNumber, currentRow, columns, params, status) {
  const now = new Date();
  const row = currentRow.slice();
  while (row.length < sheet.getLastColumn()) row.push('');
  const firstSeen = cell_(row, columns.firstSeen) || now;
  setTelemetryValues_(row, columns, params, firstSeen, now, status);

  const firstColumn = columns.accountName;
  const lastColumn = columns.historySync >= 0 ?
    columns.historySync : columns.lastResult;
  if (firstColumn < 0 || lastColumn < firstColumn) return;
  sheet.getRange(rowNumber, firstColumn + 1, 1,
    lastColumn - firstColumn + 1)
    .setValues([row.slice(firstColumn, lastColumn + 1)]);
}

function setTelemetryValues_(row, columns, params, firstSeen, lastSeen, status) {
  setCell_(row, columns.accountName, clean_(params.account_name));
  setCell_(row, columns.broker, clean_(params.broker));
  setCell_(row, columns.detectedServer, clean_(params.server));
  setCell_(row, columns.currency, clean_(params.currency));
  setCell_(row, columns.balance, numberOrBlank_(params.balance));
  setCell_(row, columns.equity, numberOrBlank_(params.equity));
  setCell_(row, columns.leverage, integerOrBlank_(params.leverage));
  setCell_(row, columns.tradeMode, clean_(params.trade_mode));
  setCell_(row, columns.symbol, clean_(params.symbol));
  setCell_(row, columns.terminal, clean_(params.terminal));
  setCell_(row, columns.terminalBuild, integerOrBlank_(params.build));
  setCell_(row, columns.firstSeen, firstSeen);
  setCell_(row, columns.lastSeen, lastSeen);
  setCell_(row, columns.lastResult, status);
  setCell_(row, columns.floatingProfit, numberOrBlank_(params.floating_profit));
  setCell_(row, columns.credit, numberOrBlank_(params.credit));
  setCell_(row, columns.margin, numberOrBlank_(params.margin));
  setCell_(row, columns.freeMargin, numberOrBlank_(params.free_margin));
  setCell_(row, columns.marginLevel, numberOrBlank_(params.margin_level));
  setCell_(row, columns.openPositions, integerOrBlank_(params.open_positions));
  setCell_(row, columns.pendingOrders, integerOrBlank_(params.pending_orders));
  setCell_(row, columns.historySync, clean_(params.history_sync));
}

function mapColumns_(headerRow) {
  const result = {
    account: -1,
    active: -1,
    expiry: -1,
    name: -1,
    allowedServer: -1,
    product: -1,
    accountName: -1,
    broker: -1,
    detectedServer: -1,
    currency: -1,
    balance: -1,
    equity: -1,
    leverage: -1,
    tradeMode: -1,
    symbol: -1,
    terminal: -1,
    terminalBuild: -1,
    firstSeen: -1,
    lastSeen: -1,
    lastResult: -1,
    floatingProfit: -1,
    credit: -1,
    margin: -1,
    freeMargin: -1,
    marginLevel: -1,
    openPositions: -1,
    pendingOrders: -1,
    historySync: -1,
  };

  headerRow.forEach(function (value, index) {
    const header = normalizeHeader_(value);
    if (['account', 'accountlogin', 'login', 'mt5account'].includes(header)) {
      result.account = index;
    } else if (['active', 'status', 'enabled'].includes(header)) {
      result.active = index;
    } else if (['expiryutc', 'expiresutc', 'expiry', 'expiration', 'expire'].includes(header)) {
      result.expiry = index;
    } else if (['name', 'customername', 'customname', 'customer', 'client'].includes(header)) {
      result.name = index;
    } else if (['allowedserver', 'server', 'serverscope'].includes(header)) {
      result.allowedServer = index;
    } else if (['product', 'ea'].includes(header)) {
      result.product = index;
    } else if (header === 'accountname') {
      result.accountName = index;
    } else if (['broker', 'company'].includes(header)) {
      result.broker = index;
    } else if (['detectedserver', 'actualserver'].includes(header)) {
      result.detectedServer = index;
    } else if (header === 'currency') {
      result.currency = index;
    } else if (header === 'balance') {
      result.balance = index;
    } else if (header === 'equity') {
      result.equity = index;
    } else if (header === 'leverage') {
      result.leverage = index;
    } else if (header === 'trademode') {
      result.tradeMode = index;
    } else if (header === 'symbol') {
      result.symbol = index;
    } else if (header === 'terminal') {
      result.terminal = index;
    } else if (['terminalbuild', 'build'].includes(header)) {
      result.terminalBuild = index;
    } else if (['firstseenutc', 'firstseen'].includes(header)) {
      result.firstSeen = index;
    } else if (['lastseenutc', 'lastseen'].includes(header)) {
      result.lastSeen = index;
    } else if (['lastresult', 'result'].includes(header)) {
      result.lastResult = index;
    } else if (['floatingprofit', 'floatingpl', 'openprofit'].includes(header)) {
      result.floatingProfit = index;
    } else if (header === 'credit') {
      result.credit = index;
    } else if (header === 'margin') {
      result.margin = index;
    } else if (['freemargin', 'marginfree'].includes(header)) {
      result.freeMargin = index;
    } else if (['marginlevel', 'marginpercent'].includes(header)) {
      result.marginLevel = index;
    } else if (['openpositions', 'positions'].includes(header)) {
      result.openPositions = index;
    } else if (['pendingorders', 'orders'].includes(header)) {
      result.pendingOrders = index;
    } else if (['historysync', 'historystatus'].includes(header)) {
      result.historySync = index;
    }
  });
  return result;
}

/**
 * Optional one-time helper. Run this manually after pasting the script if the
 * spreadsheet was not created from the supplied template.
 */
function setupLicenseSheet() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet()
    .getSheetByName(LICENSE_SHEET_NAME);
  if (!sheet) throw new Error('Missing Licenses sheet');

  sheet.getRange(1, 1, 1, LICENSE_HEADERS.length)
    .setValues([LICENSE_HEADERS]);
  sheet.setFrozenRows(1);
  sheet.setFrozenColumns(0);
  sheet.setHiddenGridlines(true);
  const dataRowCount = Math.max(sheet.getMaxRows() - 1, 1);
  try {
    sheet.getRange(2, 3, dataRowCount, 1).insertCheckboxes();
  } catch (error) {
    // The supplied native table already renders its BOOLEAN column as checks.
    console.log('Active checkbox setup skipped: ' + error.message);
  }
  sheet.getRange(2, 4, dataRowCount, 1)
    .setNumberFormat('yyyy-mm-dd hh:mm:ss');
  sheet.getRange(2, 11, dataRowCount, 2).setNumberFormat('#,##0.00');
  sheet.getRange(2, 21, dataRowCount, 5).setNumberFormat('#,##0.00');
  sheet.getRange(2, 18, dataRowCount, 2)
    .setNumberFormat('yyyy-mm-dd hh:mm:ss');
  sheet.getRange(1, 1, 1, LICENSE_HEADERS.length)
    .setBackground('#16181d')
    .setFontColor('#d4af37')
    .setFontWeight('bold')
    .setFontFamily('Carlito')
    .setFontSize(11)
    .setHorizontalAlignment('center')
    .setVerticalAlignment('middle')
    .setWrap(true);
  sheet.getRange('C1')
    .setBackground('#d4af37')
    .setFontColor('#16181d');
  sheet.setRowHeight(1, 38);
  sheet.setRowHeights(2, dataRowCount, 26);

  const widths = [
    150, 110, 80, 165, 175, 175, 160, 160, 175, 85,
    110, 110, 90, 100, 100, 130, 105, 165, 165, 150,
    120, 100, 110, 120, 110, 110, 110, 150,
  ];
  widths.forEach(function (width, index) {
    sheet.setColumnWidth(index + 1, width);
  });

  const dataRange = sheet.getRange(2, 1, dataRowCount, LICENSE_HEADERS.length);
  dataRange
    .setFontFamily('Carlito')
    .setFontSize(11)
    .setVerticalAlignment('middle');
  const rules = [
    SpreadsheetApp.newConditionalFormatRule()
      .whenFormulaSatisfied('=($B2<>"")*($C2=TRUE)')
      .setBackground('#e6f4ea')
      .setFontColor('#137333')
      .setRanges([dataRange])
      .build(),
    SpreadsheetApp.newConditionalFormatRule()
      .whenFormulaSatisfied('=($B2<>"")*($C2=FALSE)')
      .setBackground('#fce8e6')
      .setFontColor('#a50e0e')
      .setRanges([dataRange])
      .build(),
  ];
  sheet.setConditionalFormatRules(rules);

  const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
  const history = ensureTradeHistorySheet_(spreadsheet);
  history.setFrozenRows(1);
  history.setFrozenColumns(0);
  history.setHiddenGridlines(true);
  history.getRange(1, 1, 1, TRADE_HISTORY_HEADERS.length)
    .setBackground('#16181d')
    .setFontColor('#d4af37')
    .setFontWeight('bold')
    .setFontFamily('Carlito')
    .setHorizontalAlignment('center')
    .setVerticalAlignment('middle');
  history.getRange('B2:B').setNumberFormat('yyyy-mm-dd hh:mm:ss.000');
  history.getRange('H2:N').setNumberFormat('#,##0.00########');
  history.getRange('T2:T').setNumberFormat('yyyy-mm-dd hh:mm:ss');

  const dailyProfit = ensureDailyProfitSheet_(spreadsheet, history);
  formatDailyProfitSheet_(dailyProfit);
  configureDashboardWidth_(spreadsheet);
}

function normalizeHeader_(value) {
  return clean_(value).toLowerCase().replace(/[\s_-]/g, '');
}

function clean_(value) {
  return value === null || value === undefined ? '' : String(value).trim();
}

function cell_(row, index) {
  return index >= 0 && index < row.length ? row[index] : '';
}

function setCell_(row, index, value) {
  if (index >= 0) row[index] = value;
}

function scopeMatches_(configured, actual) {
  const expected = clean_(configured).toUpperCase();
  return !expected || expected === '*' || expected === clean_(actual).toUpperCase();
}

function isActive_(value) {
  return value === true || ['ACTIVE', 'ENABLED', 'TRUE', 'YES', '1', 'OK']
    .includes(clean_(value).toUpperCase());
}

function expiryUnix_(value) {
  if (value === '' || value === null || value === undefined) return 0;
  if (value instanceof Date) {
    const milliseconds = value.getTime();
    return Number.isNaN(milliseconds) ? null : Math.floor(milliseconds / 1000);
  }

  const text = clean_(value);
  if (!text || ['0', 'NEVER', 'PERMANENT', 'UNLIMITED'].includes(text.toUpperCase())) {
    return 0;
  }
  if (/^\d+$/.test(text)) {
    const unix = Number(text);
    return Number.isSafeInteger(unix) && unix > 1000000000 ? unix : null;
  }

  const milliseconds = Date.parse(text);
  return Number.isNaN(milliseconds) ? null : Math.floor(milliseconds / 1000);
}

function numberOrBlank_(value) {
  const number = Number(value);
  return clean_(value) && Number.isFinite(number) ? number : '';
}

function integerOrBlank_(value) {
  const number = Number(value);
  return clean_(value) && Number.isFinite(number) ? Math.trunc(number) : '';
}

function numberOrZero_(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : 0;
}

function safeField_(value) {
  return clean_(value).replace(/[|\r\n]/g, ' ');
}

function text_(body) {
  return ContentService.createTextOutput(body)
    .setMimeType(ContentService.MimeType.TEXT);
}
