# AI Copy (BYOK)

## API key settings screen
- Title: OpenAI API Key
- Description: Add your own OpenAI API key to enable summaries, key points, and tags.
- Field label: API Key
- Placeholder: sk-...
- Helper text: Stored in Keychain on this device. Never logged or shared.
- Link label: Get an API key
- Link URL: https://platform.openai.com/api-keys
- Buttons: Validate Key, Save, Remove Key, Cancel
- Status: Key validated, Key saved, Key removed

## Missing key banner
- Text: Add an API key to use AI features.
- Button: Add Key

## Model settings (advanced)
- Section title: Model
- Default label: Default (gpt-4o-mini)
- Helper text: Default is gpt-4o-mini for faster responses and lower cost.
- Toggle: Show advanced model options
- Field label: Model
- Options: gpt-4o-mini (default), gpt-4o (higher quality)

## Consent prompt (standard item)
- Title: Send to OpenAI?
- Body: This will send the item's title and content to OpenAI to generate a summary. Your API key will be used and OpenAI may charge usage. Continue?
- Buttons: Send, Cancel

## Consent prompt (protected item)
- Title: Send protected item to OpenAI?
- Body: This item is protected. After you unlock, its content will be sent to OpenAI for processing. Continue?
- Buttons: Send, Cancel

## Error messages
- Invalid key: Invalid API key. Check the key and try again.
- Access denied: This key does not have access to the OpenAI API.
- Billing issue: Billing problem. Check your OpenAI plan and usage.
- Rate limit: Rate limited. Try again in a few minutes.
- Service unavailable: OpenAI is unavailable right now. Try again later.
- Network: No connection. Check your network and try again.
- Model unavailable: This key cannot use the selected model. Choose another model.

## Pricing disclosure
- Text: OpenAI bills per token. Current rates (OpenAI pricing):
- Text: gpt-4o-mini: $0.15 / 1M input tokens, $0.60 / 1M output tokens.
- Text: gpt-4o: $2.50 / 1M input tokens, $10.00 / 1M output tokens.
- Text: Rates can change; see the pricing page for the latest amounts.
- Link label: OpenAI pricing
- Link URL: https://openai.com/pricing
- Link label: OpenAI usage & billing
- Link URL: https://platform.openai.com/usage
