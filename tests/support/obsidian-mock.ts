export class TFile { path = ''; }
export class Notice {
  static messages: string[] = [];
  constructor(message: string) { Notice.messages.push(message); }
}
export class MockElement {
  children: MockElement[] = [];
  text = '';
  disabled = false;
  removed = false;
  onclick?: () => Promise<void>;
  setText(text: string): void { this.text = text; }
  createDiv(): MockElement { const child = new MockElement(); this.children.push(child); return child; }
  createEl(_tag: string, options: {text: string}): MockElement {
    const child = this.createDiv(); child.text = options.text; return child;
  }
  remove(): void { this.removed = true; }
}
export class Modal {
  static last: Modal;
  titleEl = new MockElement();
  contentEl = new MockElement();
  constructor(_app: unknown) { Modal.last = this; }
  open(): void {}
}
