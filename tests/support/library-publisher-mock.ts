export {TFile, Notice, Modal} from './obsidian-mock.ts';
export const normalizePath = (path:string) => path.replaceAll('\\','/');
export const getFrontMatterInfo = (text:string) => ({exists:true,frontmatter:text,contentStart:text.length});
export const parseYaml = JSON.parse;
export const stringifyYaml = JSON.stringify;
export const DEFAULT_LIBRARY_PROPERTY_ALIASES = {title:['Title'],format:['Format'],libraryType:['Type'],cover:['Cover']};
export let transport:(options:{url:string;body?:string})=>Promise<{status:number;json:unknown}> = async()=>{throw new Error('No transport');};
export function setTransport(value:typeof transport):void {transport=value;}
export const requestUrl = (options:Parameters<typeof transport>[0])=>transport(options);
