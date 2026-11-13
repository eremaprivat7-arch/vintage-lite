function createReleaseControls(root, api) {
  let releases = [];
  let busy = false;
  root.innerHTML = `
    <details class="controls" open>
      <summary>Патч по версиям приложения</summary>
      <p>Закрой старую сборку и оставь новую доступной. Отключение общего патча сохраняет выбор в этом списке.</p>
      <p class="muted">Новые сборки появляются после успешной проверки ключа. Старые IPA без номера объединены в одну строку.</p>
      <button type="button" class="release-refresh">Обновить список</button>
      <div class="table"><table>
        <thead><tr><th>Версия</th><th>Сборка</th><th>Вход</th><th>Управление</th></tr></thead>
        <tbody></tbody>
      </table></div>
      <form class="release-form">
        <label>Версия<input name="version" placeholder="2.2.6" required pattern="[0-9]+(\\.[0-9]+){0,3}"></label>
        <label>Сборка<input name="build" placeholder="17" required pattern="[0-9]+(\\.[0-9]+){0,3}"></label>
        <label>Вход<select name="state"><option value="allow">Открыт</option><option value="block">Закрыт, требуется обновление</option></select></label>
        <button class="primary">Добавить или сохранить</button>
      </form>
      <p>Блокировка отдельной сборки сохраняет срок ключа по обычному таймеру. Клиент может продолжить с тем же ключом в разрешённой версии.</p>
      <p role="status" class="status release-message"></p>
    </details>`;
  const tbody = root.querySelector("tbody");
  const message = root.querySelector(".release-message");
  const form = root.querySelector("form");

  function showRows() {
    tbody.replaceChildren();
    for (const release of releases) {
      const row = document.createElement("tr");
      const values = [release.version === "legacy" ? "Старые сборки без номера" : release.version,
        release.build === "legacy" ? "Все прежние IPA" : release.build,
        release.blocked ? "Закрыт · обновление" : "Открыт"];
      for (const value of values) {
        const cell = document.createElement("td");
        cell.textContent = value;
        row.append(cell);
      }
      const cell = document.createElement("td");
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = release.blocked ? "Открыть вход" : "Включить патч";
      button.disabled = busy;
      button.onclick = () => {
        if (!release.blocked && !confirm("Закрыть вход для этой сборки?")) return;
        void save({ version: release.version, build: release.build, blocked: !release.blocked });
      };
      cell.append(button);
      row.append(cell);
      tbody.append(row);
    }
  }

  async function load() {
    const result = await api("/admin/api/releases");
    releases = result.releases;
    showRows();
  }

  async function save(body) {
    if (busy) return;
    busy = true;
    message.textContent = "Сохраняем…";
    root.querySelectorAll("input,select,button").forEach(node => { node.disabled = true; });
    try {
      await api("/admin/api/releases", { method: "POST", body: JSON.stringify(body) });
      await load();
      message.textContent = "Состояние версии сохранено.";
    } catch (error) {
      message.textContent = error.message;
    } finally {
      busy = false;
      root.querySelectorAll("input,select,button").forEach(node => { node.disabled = false; });
    }
  }

  form.onsubmit = event => {
    event.preventDefault();
    void save({ version: form.elements.version.value.trim(), build: form.elements.build.value.trim(),
      blocked: form.elements.state.value === "block" });
  };
  root.querySelector(".release-refresh").onclick = async () => {
    if (busy) return;
    busy = true;
    showRows();
    try {
      await load();
      message.textContent = "Список обновлён.";
    } catch (error) {
      message.textContent = error.message;
    } finally {
      busy = false;
      showRows();
    }
  };
  return load;
}
